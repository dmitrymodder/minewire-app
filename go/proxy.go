// Package minewire implements SOCKS5 and HTTP proxy handlers.
// These handlers accept local connections and forward them through
// the encrypted tunnel to the Minewire server.
package minewire

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

func handleSocks(localConn net.Conn) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("Recovered in handleSocks:", r)
		}
		localConn.Close()
	}()

	buf := make([]byte, 256)

	if _, err := io.ReadFull(localConn, buf[:2]); err != nil {
		return
	}
	nMethods := int(buf[1])
	if _, err := io.ReadFull(localConn, buf[:nMethods]); err != nil {
		return
	}
	localConn.Write([]byte{0x05, 0x00})

	if _, err := io.ReadFull(localConn, buf[:4]); err != nil {
		return
	}

	// 0x01 = CONNECT, 0x03 = UDP ASSOCIATE
	cmd := buf[1]
	if cmd != 0x01 && cmd != 0x03 {
		return
	}

	var targetAddr string
	switch buf[3] {
	case 0x01:
		ip := make([]byte, 4)
		io.ReadFull(localConn, ip)
		targetAddr = net.IP(ip).String()
	case 0x03:
		l := make([]byte, 1)
		io.ReadFull(localConn, l)
		domain := make([]byte, int(l[0]))
		io.ReadFull(localConn, domain)
		targetAddr = string(domain)
	case 0x04:
		ip := make([]byte, 16)
		io.ReadFull(localConn, ip)
		targetAddr = net.IP(ip).String()
	}

	portBuf := make([]byte, 2)
	io.ReadFull(localConn, portBuf)
	port := binary.BigEndian.Uint16(portBuf)
	fullDest := fmt.Sprintf("%s:%d", targetAddr, port)

	if cmd == 0x03 {
		handleUDPAssociate(localConn)
	} else {
		proxyToTunnel(localConn, fullDest, true)
	}
}

func handleUDPAssociate(localConn net.Conn) {
	// 1. Start a UDP listener on a random port
	udpListener, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		localConn.Write([]byte{0x05, 0x01, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer udpListener.Close()

	// 2. Send Success Reply with the Bound Address/Port
	addr := udpListener.LocalAddr().(*net.UDPAddr)
	reply := []byte{0x05, 0x00, 0, 0x01} // VER, REP, RSV, ATYP(IPv4)
	reply = append(reply, addr.IP.To4()...)
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(addr.Port))
	reply = append(reply, portBytes...)
	localConn.Write(reply)

	// 3. Keep the TCP connection alive (UDP Associate requirement)
	go func() {
		io.Copy(io.Discard, localConn)
		udpListener.Close() // Close UDP listener when TCP closes
	}()

	// 4. Handle UDP Packets
	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := udpListener.ReadFrom(buf)
		if err != nil {
			return
		}

		// Parse SOCKS UDP Header
		// RSV(2) + FRAG(1) + ATYP(1) + DST.ADDR + DST.PORT
		if n < 10 {
			continue
		}

		pos := 3 // Skip RSV, FRAG
		atyp := buf[pos]
		pos++

		var dest string
		switch atyp {
		case 0x01: // IPv4
			if n < pos+4+2 {
				continue
			}
			ip := net.IP(buf[pos : pos+4])
			pos += 4
			port := binary.BigEndian.Uint16(buf[pos : pos+2])
			pos += 2
			dest = fmt.Sprintf("%s:%d", ip.String(), port)
		case 0x03: // Domain
			l := int(buf[pos])
			pos++
			if n < pos+l+2 {
				continue
			}
			domain := string(buf[pos : pos+l])
			pos += l
			port := binary.BigEndian.Uint16(buf[pos : pos+2])
			pos += 2
			dest = fmt.Sprintf("%s:%d", domain, port)
		case 0x04: // IPv6
			if n < pos+16+2 {
				continue
			}
			ip := net.IP(buf[pos : pos+16])
			pos += 16
			port := binary.BigEndian.Uint16(buf[pos : pos+2])
			pos += 2
			dest = fmt.Sprintf("[%s]:%d", ip.String(), port)
		default:
			continue
		}

		payload := buf[pos:n]

		// Forward to Tunnel
		go sendUDPOverTunnel(dest, payload, udpListener, clientAddr)
	}
}

func sendUDPOverTunnel(dest string, data []byte, udpListener net.PacketConn, clientAddr net.Addr) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("Recovered in sendUDPOverTunnel:", r)
		}
	}()

	sessionLock.Lock()
	sess := session
	sessionLock.Unlock()
	if sess == nil {
		return
	}

	// Open stream with "udp:" prefix
	stream, err := sess.Open()
	if err != nil {
		return
	}
	defer stream.Close()

	destBuf := new(bytes.Buffer)
	WriteString(destBuf, "udp:"+dest)
	stream.Write(destBuf.Bytes())

	// Send Data (Length + Bytes)
	if err := binary.Write(stream, binary.BigEndian, uint16(len(data))); err != nil {
		return
	}
	if _, err := stream.Write(data); err != nil {
		return
	}

	// Wait for Response (with timeout)
	stream.SetReadDeadline(time.Now().Add(10 * time.Second))

	// Read Response Length
	var respLen uint16
	if err := binary.Read(stream, binary.BigEndian, &respLen); err != nil {
		return
	}

	respData := make([]byte, respLen)
	if _, err := io.ReadFull(stream, respData); err != nil {
		return
	}

	// Send back to Client (Wrap in SOCKS UDP Header)
	// RSV(2) + FRAG(1) + ATYP(1) + 0.0.0.0 + 0 + DATA
	// We cheat a bit and don't put the real source addr because tun2socks doesn't care much
	respHeader := []byte{0, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	udpListener.WriteTo(append(respHeader, respData...), clientAddr)
}

func handleHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		dest := r.Host
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
			return
		}
		clientConn, _, err := hijacker.Hijack()
		if err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
		proxyToTunnel(clientConn, dest, false)
	} else {
		http.Error(w, "Only CONNECT method supported", http.StatusMethodNotAllowed)
	}
}

func proxyToTunnel(localConn net.Conn, dest string, isSocks bool) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("Recovered in proxyToTunnel:", r)
		}
	}()

	sessionLock.Lock()
	sess := session
	sessionLock.Unlock()

	if sess == nil {
		if isSocks {
			localConn.Write([]byte{0x05, 0x01, 0, 1, 0, 0, 0, 0, 0, 0})
		}
		return
	}

	stream, err := sess.Open()
	if err != nil {
		return
	}
	defer stream.Close()

	destBuf := new(bytes.Buffer)
	WriteString(destBuf, dest)
	stream.Write(destBuf.Bytes())

	if isSocks {
		localConn.Write([]byte{0x05, 0x00, 0, 1, 0, 0, 0, 0, 0, 0})
	}

	go io.Copy(stream, localConn)
	io.Copy(localConn, stream)
}
