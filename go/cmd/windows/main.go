package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"minewire"
	"os"
	"os/signal"
	"syscall"
)

type Command struct {
	Method string      `json:"method"`
	Args   CommandArgs `json:"args"`
}

type CommandArgs struct {
	LocalPort     string `json:"localPort"`
	ServerAddress string `json:"serverAddress"`
	Password      string `json:"password"`
	ProxyType     string `json:"proxyType"`
	Link          string `json:"link"` // for parseLink
}

type Response struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    any    `json:"data,omitempty"`
}

func main() {
	// Clean up on exit
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
		msg := minewire.Start(cmd.Args.LocalPort, cmd.Args.ServerAddress, cmd.Args.Password, cmd.Args.ProxyType)
		if msg != "" {
			respond(Response{Success: false, Error: msg})
			return
		}
		// Set System Proxy
		err := setSystemProxy("127.0.0.1"+cmd.Args.LocalPort, cmd.Args.ProxyType)
		if err != nil {
			minewire.Stop()
			respond(Response{Success: false, Error: "Failed to set system proxy: " + err.Error()})
			return
		}
		respond(Response{Success: true})

	case "stop":
		minewire.Stop()
		unsetSystemProxy()
		respond(Response{Success: true})

	case "isActive":
		running := minewire.IsRunning()
		respond(Response{Success: true, Data: running})

	case "ping":
		latency := minewire.Ping(cmd.Args.ServerAddress)
		respond(Response{Success: true, Data: latency})

	case "parseLink":
		// minewire.ParseConnectionLink returns a JSON string, so we need to decode it back
		// to embed it properly in our Data field, OR just return it as a string.
		// Let's decode it for cleaner structure.
		jsonStr := minewire.ParseConnectionLink(cmd.Args.Link)
		var parsed map[string]any
		json.Unmarshal([]byte(jsonStr), &parsed)
		respond(Response{Success: true, Data: parsed})

	default:
		respond(Response{Success: false, Error: "Unknown method"})
	}
}

func respond(res Response) {
	b, _ := json.Marshal(res)
	fmt.Println(string(b))
}
