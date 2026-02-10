package main

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"github.com/hashicorp/yamux"
)

const (
	PROTOCOL_VERSION      = 773
	PID_SB_Handshake      = 0x00
	PID_SB_LoginStart     = 0x00
	PID_SB_ClientSettings = 0x08
	PID_SB_PluginMsg      = 0x0D
	PID_SB_PlayerPos      = 0x14
	PID_SB_KeepAlive      = 0x15

	PID_CB_LoginSuccess = 0x02
	PID_CB_JoinGame     = 0x29
	PID_CB_KeepAlive    = 0x24
	PID_CB_ChunkData    = 0x25
)

var (
	session         *yamux.Session
	sessionLock     sync.Mutex
	lastKeepAliveID int64
	keepAliveLock   sync.Mutex
)

func CloseSession() {
	sessionLock.Lock()
	if session != nil {
		session.Close()
		session = nil
	}
	sessionLock.Unlock()
}

func maintainSession() {
	for {
		serverLock.Lock()
		running := isRunning
		serverLock.Unlock()
		if !running {
			return
		}

		sessionLock.Lock()
		if session == nil || session.IsClosed() {
			s, err := connectToServer()
			if err == nil {
				session = s
				log.Println("✅ Connected & Logged in as Player!")
			} else {
				log.Printf("❌ Connect fail: %v", err)
			}
		}
		sessionLock.Unlock()
		time.Sleep(3 * time.Second)
	}
}

func connectToServer() (*yamux.Session, error) {
	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.Dial("tcp", cfg.ServerAddress)
	if err != nil {
		return nil, err
	}

	if tcpConn, ok := conn.(*net.TCPConn); ok {
		tcpConn.SetNoDelay(true)
		tcpConn.SetKeepAlive(true)
		tcpConn.SetKeepAlivePeriod(30 * time.Second)
	}

	h := sha256.Sum256([]byte(cfg.Password))
	username := "Player" + hex.EncodeToString(h[:])[:8]

	buf := new(bytes.Buffer)
	WriteVarInt(buf, PROTOCOL_VERSION)
	WriteString(buf, "127.0.0.1")
	buf.Write([]byte{0x63, 0xDD})
	WriteVarInt(buf, 2)
	WritePacket(conn, PID_SB_Handshake, buf.Bytes())

	buf.Reset()
	WriteString(buf, username)
	WritePacket(conn, PID_SB_LoginStart, buf.Bytes())

	conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReader(conn)
	packetsToRead := 2
	for packetsToRead > 0 {
		l, err := ReadVarInt(reader)
		if err != nil {
			conn.Close()
			return nil, err
		}
		_, err = io.ReadFull(reader, make([]byte, l))
		if err != nil {
			conn.Close()
			return nil, err
		}
		packetsToRead--
	}
	conn.SetReadDeadline(time.Time{})

	buf.Reset()
	WriteString(buf, "en_US")
	WriteByte(buf, 8)
	WriteVarInt(buf, 0)
	WriteBool(buf, true)
	WriteByte(buf, 0x7F)
	WriteVarInt(buf, 1)
	WriteBool(buf, false)
	WriteBool(buf, true)
	WritePacket(conn, PID_SB_ClientSettings, buf.Bytes())

	key := sha256.Sum256([]byte(cfg.Password))
	block, _ := aes.NewCipher(key[:])
	aead, _ := cipher.NewGCM(block)

	pr, pw := io.Pipe()
	mc := &MinecraftConn{
		conn:      conn,
		r:         pr,
		w:         pw,
		aead:      aead,
		rawReader: reader,
		writeBuf:  bytes.NewBuffer(make([]byte, 0, 16384)),
	}

	go startBackgroundNoise(conn)
	go startReaderLoop(mc, pw, conn, aead)

	conf := yamux.DefaultConfig()
	conf.KeepAliveInterval = 30 * time.Second
	conf.ConnectionWriteTimeout = 15 * time.Second
	conf.MaxStreamWindowSize = 512 * 1024 // 512KB (Optimized)
	conf.StreamOpenTimeout = 30 * time.Second
	conf.LogOutput = io.Discard
	return yamux.Client(mc, conf)
}

func startBackgroundNoise(conn net.Conn) {
	posTicker := time.NewTicker(1 * time.Second)
	// kaTicker removed
	defer posTicker.Stop()
	posX, posY, posZ := 100.5, 64.0, 100.5
	for {
		select {
		case <-posTicker.C:
			serverLock.Lock()
			running := isRunning
			serverLock.Unlock()
			if !running {
				return
			}

			jitter := (float64(time.Now().UnixNano()%100) / 5000.0)
			b := new(bytes.Buffer)
			WriteDouble(b, posX+jitter)
			WriteDouble(b, posY)
			WriteDouble(b, posZ+jitter)
			WriteBool(b, true)
			WritePacket(conn, PID_SB_PlayerPos, b.Bytes())
			// Removed redundant kaTicker logic here
		}
	}
}

func startReaderLoop(mc *MinecraftConn, pw *io.PipeWriter, conn net.Conn, aead cipher.AEAD) {
	defer pw.Close()
	defer conn.Close()
	var r io.ByteReader
	if br, ok := mc.rawReader.(io.ByteReader); ok {
		r = br
	} else {
		r = bufio.NewReader(mc.rawReader)
	}

	for {
		l, err := ReadVarInt(r)
		if err != nil {
			return
		}
		if l < 0 || l > 2097152 {
			return
		}

		data := make([]byte, l)
		_, err = io.ReadFull(mc.rawReader, data)
		if err != nil {
			return
		}

		pBuf := bytes.NewBuffer(data)
		pid, _ := ReadVarInt(pBuf)

		if pid == PID_CB_ChunkData {
			if pBuf.Len() < 8 {
				continue
			}
			pBuf.Next(8)

			if err := skipNBT(pBuf); err != nil {
				continue
			}

			payloadSize, err := ReadVarInt(pBuf)
			if err != nil {
				continue
			}
			if pBuf.Len() < payloadSize {
				continue
			}

			enc := pBuf.Next(payloadSize)
			if len(enc) < aead.NonceSize() {
				continue
			}
			nonce := enc[:aead.NonceSize()]
			pt, err := aead.Open(nil, nonce, enc[aead.NonceSize():], nil)
			if err == nil {
				pw.Write(pt)
			}

		} else if pid == PID_CB_KeepAlive {
			var kId int64
			if pBuf.Len() >= 8 {
				binary.Read(pBuf, binary.BigEndian, &kId)
				// Immediate Reply!
				// No need to store in global var or wait for ticker.
				// This is optimal event-driven behavior.
				b := new(bytes.Buffer)
				WriteLong(b, kId)
				WritePacket(conn, PID_SB_KeepAlive, b.Bytes())
			}
		}
	}
}

func skipNBT(r *bytes.Buffer) error {
	tagType, err := r.ReadByte()
	if err != nil {
		return err
	}
	if tagType == 0 {
		return nil
	}
	nameLen := int(binary.BigEndian.Uint16(r.Next(2)))
	r.Next(nameLen)
	return skipNBTPayload(r, tagType)
}

func skipNBTPayload(r *bytes.Buffer, tagType byte) error {
	switch tagType {
	case 1:
		r.Next(1)
	case 2:
		r.Next(2)
	case 3:
		r.Next(4)
	case 4:
		r.Next(8)
	case 5:
		r.Next(4)
	case 6:
		r.Next(8)
	case 7:
		l := int(int32(binary.BigEndian.Uint32(r.Next(4))))
		r.Next(l)
	case 8:
		l := int(uint16(binary.BigEndian.Uint16(r.Next(2))))
		r.Next(l)
	case 9:
		subType, _ := r.ReadByte()
		l := int(int32(binary.BigEndian.Uint32(r.Next(4))))
		for i := 0; i < l; i++ {
			skipNBTPayload(r, subType)
		}
	case 10:
		for {
			subType, _ := r.ReadByte()
			if subType == 0 {
				break
			}
			nLen := int(binary.BigEndian.Uint16(r.Next(2)))
			r.Next(nLen)
			skipNBTPayload(r, subType)
		}
	case 11:
		l := int(int32(binary.BigEndian.Uint32(r.Next(4))))
		r.Next(l * 4)
	case 12:
		l := int(int32(binary.BigEndian.Uint32(r.Next(4))))
		r.Next(l * 8)
	}
	return nil
}

type MinecraftConn struct {
	conn      net.Conn
	r         *io.PipeReader
	w         *io.PipeWriter
	aead      cipher.AEAD
	rawReader io.Reader

	writeBuf   *bytes.Buffer
	writeMu    sync.Mutex
	flushTimer *time.Timer
}

func (mc *MinecraftConn) Read(b []byte) (int, error) { return mc.r.Read(b) }

func (mc *MinecraftConn) flushLocked() error {
	if mc.flushTimer != nil {
		mc.flushTimer.Stop()
		mc.flushTimer = nil
	}

	if mc.writeBuf.Len() == 0 {
		return nil
	}
	data := mc.writeBuf.Bytes()

	nonce := make([]byte, mc.aead.NonceSize())
	rand.Read(nonce)
	encrypted := mc.aead.Seal(nonce, nonce, data, nil)
	buf := new(bytes.Buffer)
	WriteString(buf, "minecraft:brand")
	buf.Write(encrypted)

	err := WritePacket(mc.conn, PID_SB_PluginMsg, buf.Bytes())

	mc.writeBuf.Reset()
	return err
}

func (mc *MinecraftConn) Write(b []byte) (int, error) {
	mc.writeMu.Lock()
	defer mc.writeMu.Unlock()

	n, err := mc.writeBuf.Write(b)
	if err != nil {
		return 0, err
	}

	// 4KB threshold for immediate flush
	if mc.writeBuf.Len() >= 4096 {
		if err := mc.flushLocked(); err != nil {
			return n, err
		}
	} else {
		// Delayed flush for small packets
		if mc.flushTimer == nil {
			mc.flushTimer = time.AfterFunc(5*time.Millisecond, func() {
				mc.writeMu.Lock()
				defer mc.writeMu.Unlock()
				mc.flushLocked()
			})
		}
	}
	return n, nil
}

func (mc *MinecraftConn) Close() error {
	mc.writeMu.Lock()
	if mc.flushTimer != nil {
		mc.flushTimer.Stop()
	}
	mc.writeMu.Unlock()
	return mc.conn.Close()
}
func (mc *MinecraftConn) LocalAddr() net.Addr                { return mc.conn.LocalAddr() }
func (mc *MinecraftConn) RemoteAddr() net.Addr               { return mc.conn.RemoteAddr() }
func (mc *MinecraftConn) SetDeadline(t time.Time) error      { return mc.conn.SetDeadline(t) }
func (mc *MinecraftConn) SetReadDeadline(t time.Time) error  { return mc.conn.SetReadDeadline(t) }
func (mc *MinecraftConn) SetWriteDeadline(t time.Time) error { return mc.conn.SetWriteDeadline(t) }
