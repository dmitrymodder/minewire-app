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

	var proxyVal string
	if proxyType == "socks5" {
		proxyVal = "socks=" + addr
	} else {
		proxyVal = addr
	}

	if err = k.SetStringValue("ProxyServer", proxyVal); err != nil {
		return err
	}

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
