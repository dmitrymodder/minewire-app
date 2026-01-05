// Package minewire implements the core VPN tunnel client library.
// It provides SOCKS5/HTTP proxy functionality and manages the encrypted tunnel
// to the Minewire server, disguised as Minecraft protocol traffic.
package minewire

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eycorsican/go-tun2socks/core"
	"github.com/eycorsican/go-tun2socks/proxy/socks"
)

// ProtectCallback allows Android VpnService to protect the socket
type ProtectCallback interface {
	Protect(fd int) bool
}

var protector ProtectCallback

// SetProtectCallback sets the callback for socket protection
func SetProtectCallback(cb ProtectCallback) {
	protector = cb
}

// UpdateConfig updates the split tunneling rules
func UpdateConfig(rulePaths string) {
	st := GetSplitTunnelManager()
	st.ClearRules()

	paths := strings.Split(rulePaths, ",")
	for _, path := range paths {
		if path == "" {
			continue
		}
		if err := st.LoadRuleFile(path); err != nil {
			log.Printf("Failed to load rule file %s: %v", path, err)
		} else {
			log.Printf("Loaded rule file: %s", path)
		}
	}
}

// Ping measures latency to the given server address (host:port).
// Returns latency in milliseconds, or -1 on error.
func Ping(serverAddr string) int64 {
	start := time.Now()
	conn, err := net.DialTimeout("tcp", serverAddr, 5*time.Second)
	if err != nil {
		return -1
	}
	conn.Close()
	return time.Since(start).Milliseconds()
}

// Traffic counters
var (
	bytesUploaded   atomic.Int64
	bytesDownloaded atomic.Int64
)

// GetTxBytes returns total bytes uploaded (Read from TUN)
func GetTxBytes() int64 {
	return bytesUploaded.Load()
}

// GetRxBytes returns total bytes downloaded (Written to TUN)
func GetRxBytes() int64 {
	return bytesDownloaded.Load()
}

// IsRunning returns true if the VPN is running
func IsRunning() bool {
	serverLock.Lock()
	defer serverLock.Unlock()
	return isRunning
}

// Global control
var (
	isRunning  bool
	serverLock sync.Mutex
	listener   net.Listener
	httpServer *http.Server
	ew         core.LWIPStack
	tunFile    *os.File // Store reference to close it on Stop
)

// Config internal
var cfg struct {
	LocalPort     string
	ServerAddress string
	Password      string
	ProxyType     string
}

// Start starts the SOCKS/HTTP proxy and tunnel connection.
// Returns an error string or empty string on success.
var readyChan chan struct{}

func Start(localPort, serverAddr, password, proxyType string) string {
	serverLock.Lock()
	defer serverLock.Unlock()

	if isRunning {
		return "Already running"
	}

	cfg.LocalPort = localPort
	cfg.ServerAddress = serverAddr
	cfg.Password = password
	cfg.ProxyType = proxyType
	readyChan = make(chan struct{})

	// Reset existing sessions
	CloseSession()

	isRunning = true

	// Start tunnel maintenance goroutine (tunnel.go)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Println("Recovered in maintainSession:", r)
			}
		}()
		maintainSession()
	}()

	// Start local proxy server goroutine
	go func() {
		defer func() {
			if r := recover(); r != nil {
				// log.Println("Recovered in proxy:", r)
			}
		}()
		var err error
		if cfg.ProxyType == "http" {
			err = startHTTPProxy()
		} else {
			err = startSOCKSProxy()
		}
		if err != nil {
			log.Printf("Proxy Error: %v", err)
			Stop()
		}
	}()

	// Note: We don't wait for readyChan here to avoid blocking gomobile context
	// The proxy will signal readiness asynchronously

	return ""
}

// StartVpn starts processing packets from the Android VPN interface.
// fd is the file descriptor of the TUN interface.
func StartVpn(fd int) {
	defer func() {
		if r := recover(); r != nil {
			log.Println("Recovered in StartVpn:", r)
		}
	}()

	// Create file from TUN file descriptor
	serverLock.Lock()
	tunFile = os.NewFile(uintptr(fd), "tun")
	serverLock.Unlock()

	defer func() {
		serverLock.Lock()
		if tunFile != nil {
			tunFile.Close()
			tunFile = nil
		}
		serverLock.Unlock()
	}()

	// Wait for local proxy to start
	select {
	case <-readyChan:
	case <-time.After(5 * time.Second):
		log.Println("Proxy startup timeout")
		return
	}

	// Configure tun2socks output function
	core.RegisterOutputFn(func(data []byte) (int, error) {
		// Safe write check
		serverLock.Lock()
		f := tunFile
		serverLock.Unlock()
		if f == nil {
			return 0, net.ErrClosed
		}
		n, err := f.Write(data)
		if n > 0 {
			bytesDownloaded.Add(int64(n))
		}
		return n, err
	})

	// Use local variable for stack to avoid race with Stop() setting global ew to nil
	stack := core.NewLWIPStack()
	ew = stack

	portStr := strings.TrimPrefix(cfg.LocalPort, ":")
	port := uint16(atoi(portStr))
	socksTarget := "127.0.0.1"

	// Reset counters on start
	bytesUploaded.Store(0)
	bytesDownloaded.Store(0)

	tcpHandler := socks.NewTCPHandler(socksTarget, port)
	udpHandler := socks.NewUDPHandler(socksTarget, port, 30*time.Second)

	core.RegisterTCPConnHandler(tcpHandler)
	core.RegisterUDPConnHandler(udpHandler)

	// Start packet read loop
	log.Println("StartVpn: Starting Read Loop")

	// Optimization: Cache tunFile locally.
	// If Stop() is called, it will Close() this file, causing Read() to error.
	f := tunFile

	for {
		// Allocate fresh buffer to avoid race conditions with tun2socks stack
		buf := make([]byte, 1500)

		n, err := f.Read(buf)
		if err != nil {
			// Log only if we are still running, otherwise it's expected shutdown
			serverLock.Lock()
			running := isRunning
			serverLock.Unlock()
			if running {
				log.Printf("StartVpn Read Error: %v", err)
			} else {
				log.Println("StartVpn: Stopping due to app shutdown")
			}
			break
		}
		if n > 0 {
			bytesUploaded.Add(int64(n))
			// Write to local stack variable which is safe
			_, err = stack.Write(buf[:n])
			if err != nil {
				// log.Printf("Stack Write Error: %v", err)
			}
		}
	}
	log.Println("StartVpn: Exited")
}

func atoi(s string) int {
	var n int
	for _, ch := range []byte(s) {
		ch -= '0'
		if ch > 9 {
			return 0
		}
		n = n*10 + int(ch)
	}
	return n
}

func Stop() {
	serverLock.Lock()
	if !isRunning {
		serverLock.Unlock()
		return
	}
	isRunning = false

	// Capture resources to close and nil them under lock
	tf := tunFile
	tunFile = nil

	hs := httpServer
	httpServer = nil

	l := listener
	listener = nil

	stack := ew
	ew = nil

	// Release lock BEFORE closing resources to prevent deadlocks
	// (e.g. ew.Close() triggering OutputFn which needs lock)
	serverLock.Unlock()

	// Close TUN file to break the StartVpn Read loop
	if tf != nil {
		tf.Close()
	}

	if cfg.ProxyType == "http" && hs != nil {
		hs.Close()
	} else if l != nil {
		l.Close()
	}

	if stack != nil {
		stack.Close()
	}

	CloseSession()
	log.Println("Minewire stopped")
}

func startSOCKSProxy() error {
	var err error
	listener, err = net.Listen("tcp", cfg.LocalPort)
	if err != nil {
		return err
	}
	log.Println("Listening for SOCKS5 on " + cfg.LocalPort)

	// Signal that proxy is ready
	close(readyChan)

	for {
		c, err := listener.Accept()
		if err != nil {
			// Check if we're shutting down
			if !IsRunning() {
				return nil // Normal shutdown
			}
			// Additional check for closed connection error
			if strings.Contains(err.Error(), "use of closed network connection") {
				return nil
			}
			return err
		}
		go handleSocks(c)
	}
}

func startHTTPProxy() error {
	httpServer = &http.Server{
		Addr:    cfg.LocalPort,
		Handler: http.HandlerFunc(handleHTTP),
	}
	log.Println("Listening for HTTP CONNECT on " + cfg.LocalPort)

	// Signal that proxy is ready
	close(readyChan)

	if err := httpServer.ListenAndServe(); err != http.ErrServerClosed {
		// Check if we're shutting down
		if !IsRunning() {
			return nil
		}
		return err
	}
	return nil
}

func ParseConnectionLink(link string) string {
	u, err := url.Parse(link)
	if err != nil {
		return fmt.Sprintf(`{"error": "%s"}`, err.Error())
	}

	if u.Scheme != "mw" {
		return `{"error": "Invalid scheme. Must be mw://"}`
	}

	password := u.User.Username()
	server := u.Host
	name := u.Fragment

	if decodedName, err := url.QueryUnescape(name); err == nil {
		name = decodedName
	}

	res := map[string]string{
		"name":     name,
		"server":   server,
		"password": password,
	}

	b, _ := json.Marshal(res)
	return string(b)
}
