package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Global Config & State (Replicated from minewire.go but simplified)
var (
	cfg struct {
		LocalPort     string
		ServerAddress string
		Password      string
		ProxyType     string
	}
	isRunning  bool
	serverLock sync.Mutex
	listener   net.Listener
	httpServer *http.Server
	stopSignal chan struct{}
	debugLog   *os.File
)

func init() {
	var err error
	tempDir := os.TempDir()
	logPath := filepath.Join(tempDir, "minewire_debug.log")
	debugLog, err = os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		// ignore
	}
	logDebug("Minewire Core Initialized")
}

func logDebug(format string, v ...interface{}) {
	if debugLog != nil {
		fmt.Fprintf(debugLog, time.Now().Format(time.RFC3339)+" "+format+"\n", v...)
	}
}

// --- Command Structures ---
type Command struct {
	ID     string      `json:"id"`
	Method string      `json:"method"`
	Args   CommandArgs `json:"args"`
}

type CommandArgs struct {
	LocalPort     string `json:"localPort"`
	ServerAddress string `json:"serverAddress"`
	Password      string `json:"password"`
	ProxyType     string `json:"proxyType"`
	Link          string `json:"link"`
	Rules         string `json:"rules"` // Comma separated paths to zone files
}

type Response struct {
	ID      string `json:"id"`
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    any    `json:"data,omitempty"`
}

func main() {
	// Setup Signal Handler for Cleanup
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		unsetSystemProxy()
		os.Exit(0)
	}()

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		var cmd Command
		if err := json.Unmarshal([]byte(line), &cmd); err != nil {
			respond(Response{Success: false, Error: "Parse error: " + err.Error()})
			continue
		}
		handleCommand(cmd)
	}
}

func handleCommand(cmd Command) {
	switch cmd.Method {
	case "start":
		err := Start(cmd.Args.LocalPort, cmd.Args.ServerAddress, cmd.Args.Password, cmd.Args.ProxyType)
		if err != nil {
			respond(Response{ID: cmd.ID, Success: false, Error: err.Error()})
			return
		}
		// Set System Proxy
		if err := setSystemProxy("127.0.0.1"+cmd.Args.LocalPort, cmd.Args.ProxyType); err != nil {
			Stop()
			respond(Response{ID: cmd.ID, Success: false, Error: "System Proxy Error: " + err.Error()})
			return
		}
		respond(Response{ID: cmd.ID, Success: true})

	case "stop":
		Stop()
		unsetSystemProxy()
		respond(Response{ID: cmd.ID, Success: true})

	case "isActive":
		serverLock.Lock()
		running := isRunning
		serverLock.Unlock()
		respond(Response{ID: cmd.ID, Success: true, Data: running})

	case "ping":
		latency := Ping(cmd.Args.ServerAddress)
		respond(Response{ID: cmd.ID, Success: true, Data: latency})

	case "parseLink":
		res := ParseConnectionLink(cmd.Args.Link)
		respond(Response{ID: cmd.ID, Success: true, Data: res})

	case "getServerStatus":
		res := GetServerStatus(cmd.Args.ServerAddress)
		respond(Response{ID: cmd.ID, Success: true, Data: res})

	case "updateConfig":
		paths := strings.Split(cmd.Args.Rules, ",")
		st := GetSplitTunnelManager()

		logDebug("Updating Rules: %s", cmd.Args.Rules)

		if err := st.UpdateRules(paths); err != nil {
			respond(Response{ID: cmd.ID, Success: false, Error: err.Error()})
		} else {
			respond(Response{ID: cmd.ID, Success: true})
		}

	default:
		respond(Response{ID: cmd.ID, Success: false, Error: "Unknown method"})
	}
}

func respond(res Response) {
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
}

// --- Core Logic (Adapted from minewire.go/client main.go) ---

func Start(localPort, serverAddr, password, proxyType string) error {
	serverLock.Lock()
	defer serverLock.Unlock()

	if isRunning {
		return fmt.Errorf("already running")
	}

	cfg.LocalPort = localPort
	cfg.ServerAddress = serverAddr
	cfg.Password = password
	cfg.ProxyType = proxyType

	stopSignal = make(chan struct{})
	isRunning = true

	// 1. Reset Session
	CloseSession()

	// 2. Start Tunnel Maintenance
	go func() {
		maintainSession()
	}()

	// 3. Start Local Proxy
	go func() {
		var err error
		if cfg.ProxyType == "http" {
			err = startHTTPProxy()
		} else {
			err = startSOCKSProxy()
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "Proxy Error: %v\n", err)
			Stop() // safe? locking inside Stop
		}
	}()

	return nil
}

func Stop() {
	serverLock.Lock()
	defer serverLock.Unlock()

	if !isRunning {
		return
	}
	isRunning = false

	if stopSignal != nil {
		close(stopSignal)
	}

	if listener != nil {
		listener.Close()
		listener = nil
	}
	if httpServer != nil {
		httpServer.Close()
		httpServer = nil
	}

	CloseSession() // In tunnel.go
}

func startSOCKSProxy() error {
	var err error
	listener, err = net.Listen("tcp", cfg.LocalPort)
	if err != nil {
		return err
	}

	for {
		c, err := listener.Accept()
		if err != nil {
			// Check if stopped
			if !isRunning {
				return nil
			}
			return err
		}
		go handleSocks(c) // In proxy.go
	}
}

func startHTTPProxy() error {
	httpServer = &http.Server{
		Addr:    cfg.LocalPort,
		Handler: http.HandlerFunc(handleHTTP), // In proxy.go
	}

	if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
		if !isRunning {
			return nil
		}
		return err
	}
	return nil
}

func Ping(serverAddr string) int64 {
	start := time.Now()
	conn, err := net.DialTimeout("tcp", serverAddr, 5*time.Second)
	if err != nil {
		return -1
	}
	conn.Close()
	return time.Since(start).Milliseconds()
}

// GetServerStatus queries the server for MOTD, Icon, and Player count.
func GetServerStatus(serverAddr string) string {
	conn, err := net.DialTimeout("tcp", serverAddr, 5*time.Second)
	if err != nil {
		return fmt.Sprintf(`{"error": "%s"}`, err.Error())
	}
	defer conn.Close()

	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)
	}

	// 1. Handshake State 1 (Status)
	host, portStr, _ := net.SplitHostPort(serverAddr)
	port := 25565
	if p, err := parsePort(portStr); err == nil {
		port = p
	}

	buf := new(bytes.Buffer)
	WriteVarInt(buf, -1)          // Protocol Version
	WriteString(buf, host)        // Host
	WriteShort(buf, uint16(port)) // Port
	WriteVarInt(buf, 1)           // State 1 (Status)
	if err := WritePacket(conn, 0x00, buf.Bytes()); err != nil {
		return fmt.Sprintf(`{"error": "%s"}`, err.Error())
	}

	// 2. Status Request
	if err := WritePacket(conn, 0x00, []byte{}); err != nil {
		return fmt.Sprintf(`{"error": "%s"}`, err.Error())
	}

	// 3. Read Response
	br := bufio.NewReader(conn)

	// Read Packet Length
	_, err = ReadVarInt(br)
	if err != nil {
		return fmt.Sprintf(`{"error": "Read Len: %s"}`, err.Error())
	}
	// Read Packet ID
	pid, err := ReadVarInt(br)
	if err != nil {
		return fmt.Sprintf(`{"error": "Read PID: %s"}`, err.Error())
	}
	if pid != 0x00 {
		return fmt.Sprintf(`{"error": "Invalid PID: %d"}`, pid)
	}

	// Read JSON String
	jsonStr, err := ReadString(br)
	if err != nil {
		return fmt.Sprintf(`{"error": "Read String: %s"}`, err.Error())
	}

	return jsonStr
}

func parsePort(s string) (int, error) {
	var n int
	for _, ch := range []byte(s) {
		ch -= '0'
		if ch > 9 {
			return 0, fmt.Errorf("invalid port")
		}
		n = n*10 + int(ch)
	}
	return n, nil
}

func WriteShort(w io.Writer, v uint16) {
	binary.Write(w, binary.BigEndian, v)
}

func ParseConnectionLink(link string) map[string]string {
	u, err := url.Parse(link)
	if err != nil {
		return map[string]string{"error": err.Error()}
	}
	if u.Scheme != "mw" {
		return map[string]string{"error": "Invalid scheme"}
	}

	name := u.Fragment
	if decoded, err := url.QueryUnescape(name); err == nil {
		name = decoded
	}

	return map[string]string{
		"name":     name,
		"server":   u.Host,
		"password": u.User.Username(),
	}
}
