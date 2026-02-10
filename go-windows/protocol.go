package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
)

func ReadVarInt(r io.ByteReader) (int, error) {
	var numRead int
	var result int
	for {
		read, err := r.ReadByte()
		if err != nil {
			return 0, err
		}
		value := int(read & 0x7F)
		result |= value << (7 * numRead)

		numRead++
		if numRead > 5 {
			return 0, errors.New("varint is too big")
		}

		if (read & 0x80) == 0 {
			break
		}
	}
	return result, nil
}

func WriteVarInt(w io.Writer, value int) error {
	ux := uint32(value)
	for {
		temp := byte(ux & 0x7F)
		ux >>= 7
		if ux != 0 {
			temp |= 0x80
		}
		if _, err := w.Write([]byte{temp}); err != nil {
			return err
		}
		if ux == 0 {
			break
		}
	}
	return nil
}

func WriteString(w io.Writer, s string) error {
	b := []byte(s)
	if err := WriteVarInt(w, len(b)); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

func ReadString(r io.Reader) (string, error) {
	var br io.ByteReader
	if b, ok := r.(io.ByteReader); ok {
		br = b
	} else {
		buf := make([]byte, 1)
		br = &byteReaderAdapter{r: r, buf: buf}
	}

	length, err := ReadVarInt(br)
	if err != nil {
		return "", err
	}
	if length > 32773 {
		return "", errors.New("string too long")
	}

	bytes := make([]byte, length)
	if _, err := io.ReadFull(r, bytes); err != nil {
		return "", err
	}
	return string(bytes), nil
}

type byteReaderAdapter struct {
	r   io.Reader
	buf []byte
}

func (b *byteReaderAdapter) ReadByte() (byte, error) {
	_, err := b.r.Read(b.buf)
	return b.buf[0], err
}

func WriteBool(w io.Writer, b bool) {
	var v byte
	if b {
		v = 0x01
	}
	w.Write([]byte{v})
}

func WriteByte(w io.Writer, b byte) {
	w.Write([]byte{b})
}

func WriteLong(w io.Writer, v int64) {
	binary.Write(w, binary.BigEndian, v)
}

func WriteInt(w io.Writer, v int32) {
	binary.Write(w, binary.BigEndian, v)
}

func WriteFloat(w io.Writer, v float32) {
	binary.Write(w, binary.BigEndian, v)
}

func WriteDouble(w io.Writer, v float64) {
	binary.Write(w, binary.BigEndian, v)
}

func WritePacket(w io.Writer, packetID int, data []byte) error {
	packetBuffer := new(bytes.Buffer)
	WriteVarInt(packetBuffer, packetID)
	packetBuffer.Write(data)
	length := packetBuffer.Len()
	if err := WriteVarInt(w, length); err != nil {
		return err
	}
	if _, err := w.Write(packetBuffer.Bytes()); err != nil {
		return err
	}
	return nil
}
