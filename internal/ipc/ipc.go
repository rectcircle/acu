package ipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

const MaxMessageSize = 16 << 10

var ErrMessageTooLarge = errors.New("IPC message exceeds 16 KiB")

type Message struct {
	Type           string `json:"type"`
	Token          string `json:"token,omitempty"`
	Mode           string `json:"mode,omitempty"`
	State          string `json:"state,omitempty"`
	Code           string `json:"code,omitempty"`
	Success        bool   `json:"success,omitempty"`
	TimeoutSeconds int    `json:"timeoutSeconds,omitempty"`
}

type Conn struct {
	reader *bufio.Reader
	writer io.Writer
	closer []io.Closer
	mu     sync.Mutex
}

func New(reader io.Reader, writer io.Writer, closers ...io.Closer) *Conn {
	return &Conn{
		reader: bufio.NewReaderSize(reader, MaxMessageSize),
		writer: writer,
		closer: closers,
	}
}

func (c *Conn) Read() (Message, error) {
	line, err := c.reader.ReadSlice('\n')
	if errors.Is(err, bufio.ErrBufferFull) {
		return Message{}, ErrMessageTooLarge
	}
	if err != nil {
		return Message{}, err
	}
	if len(line) > MaxMessageSize {
		return Message{}, ErrMessageTooLarge
	}

	var message Message
	if err := json.Unmarshal(line, &message); err != nil {
		return Message{}, err
	}
	return message, nil
}

func (c *Conn) Write(message Message) error {
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	if len(data)+1 > MaxMessageSize {
		return ErrMessageTooLarge
	}
	data = append(data, '\n')

	c.mu.Lock()
	defer c.mu.Unlock()
	_, err = c.writer.Write(data)
	return err
}

func (c *Conn) Close() error {
	var result error
	for _, closer := range c.closer {
		if err := closer.Close(); err != nil && result == nil {
			result = err
		}
	}
	return result
}
