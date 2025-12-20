package main

import (
	"fmt"

	"golang.org/x/sys/windows/registry"
)

func setSystemProxy(addr string, proxyType string) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.ALL_ACCESS)
	if err != nil {
		return fmt.Errorf("could not open registry key: %v", err)
	}
	defer k.Close()

	if err = k.SetDWordValue("ProxyEnable", 1); err != nil {
		return err
	}

	// Format: "socks=127.0.0.1:1080" or "127.0.0.1:1080" for HTTP
	// Usually Windows interprets "ip:port" as HTTP proxy for all protocols if not specified.
	// But for SOCKS we specifically need "socks=ip:port".
	// For HTTP, we can use "http=ip:port;https=ip:port" or just "ip:port".

	var proxyVal string
	if proxyType == "socks5" {
		proxyVal = "socks=" + addr
	} else {
		// http
		proxyVal = addr
	}

	if err = k.SetStringValue("ProxyServer", proxyVal); err != nil {
		return err
	}

	// Bypass local addresses
	if err := k.SetStringValue("ProxyOverride", "<local>"); err != nil {
		return err
	}

	return nil
}

func unsetSystemProxy() error {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.ALL_ACCESS)
	if err != nil {
		return fmt.Errorf("could not open registry key: %v", err)
	}
	defer k.Close()

	return k.SetDWordValue("ProxyEnable", 0)
}
