package ipc

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestConnRoundTrip(t *testing.T) {
	var stream bytes.Buffer
	writer := New(strings.NewReader(""), &stream)
	want := Message{
		Type:  "hello",
		Token: "token",
		Mode:  "keep_awake",
	}
	if err := writer.Write(want); err != nil {
		t.Fatal(err)
	}

	reader := New(&stream, &bytes.Buffer{})
	got, err := reader.Read()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestConnRejectsOversizedRead(t *testing.T) {
	input := strings.Repeat("x", MaxMessageSize) + "\n"
	conn := New(strings.NewReader(input), &bytes.Buffer{})
	if _, err := conn.Read(); !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("expected ErrMessageTooLarge, got %v", err)
	}
}

func TestConnRejectsOversizedWrite(t *testing.T) {
	conn := New(strings.NewReader(""), &bytes.Buffer{})
	err := conn.Write(Message{
		Type:  "fatal",
		Token: strings.Repeat("x", MaxMessageSize),
	})
	if !errors.Is(err, ErrMessageTooLarge) {
		t.Fatalf("expected ErrMessageTooLarge, got %v", err)
	}
}
