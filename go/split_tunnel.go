package minewire

import (
	"bufio"
	"net"
	"os"
	"strings"
	"sync"

	"github.com/yl2chen/cidranger"
)

// SplitTunnelManager handles split tunneling logic
type SplitTunnelManager struct {
	ranger cidranger.Ranger
	mu     sync.RWMutex
}

var (
	stManager *SplitTunnelManager
	stOnce    sync.Once
)

// GetSplitTunnelManager returns the singleton instance
func GetSplitTunnelManager() *SplitTunnelManager {
	stOnce.Do(func() {
		stManager = &SplitTunnelManager{
			ranger: cidranger.NewPCTrieRanger(),
		}
	})
	return stManager
}

// ClearRules clears all loaded CIDR rules
func (m *SplitTunnelManager) ClearRules() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.ranger = cidranger.NewPCTrieRanger()
}

// LoadRuleFile loads a file containing CIDR ranges (one per line)
func (m *SplitTunnelManager) LoadRuleFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	m.mu.Lock()
	defer m.mu.Unlock()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		_, network, err := net.ParseCIDR(line)
		if err != nil {
			// Try parsing as single IP, assume /32
			ip := net.ParseIP(line)
			if ip != nil {
				mask := net.CIDRMask(32, 32)
				if ip.To4() == nil {
					mask = net.CIDRMask(128, 128)
				}
				network = &net.IPNet{IP: ip, Mask: mask}
			} else {
				continue // Skip invalid lines
			}
		}
		m.ranger.Insert(cidranger.NewBasicRangerEntry(*network))
	}
	return scanner.Err()
}

// ShouldBypass returns true if the IP should be routed directly (bypass VPN)
func (m *SplitTunnelManager) ShouldBypass(ipStr string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	contains, err := m.ranger.Contains(ip)
	if err != nil {
		return false
	}
	return contains
}
