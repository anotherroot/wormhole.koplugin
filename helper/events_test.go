package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestEmitWritesOneJSONLine(t *testing.T) {
	var buf bytes.Buffer
	NewEmitter(&buf).Emit(Event{Ev: "code", Code: "7-guitarist-revenge"})
	if got := buf.String(); got != `{"ev":"code","code":"7-guitarist-revenge"}`+"\n" {
		t.Fatalf("got %q", got)
	}
}

func TestProgressIsThrottledButLastAlwaysSent(t *testing.T) {
	var buf bytes.Buffer
	em := NewEmitter(&buf)
	for i := int64(1); i <= 100; i++ {
		em.Progress(i, 100)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("want first + last, got %d lines: %v", len(lines), lines)
	}
	if lines[1] != `{"ev":"progress","done":100,"total":100}` {
		t.Fatalf("last line %q", lines[1])
	}
}

func TestClassify(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{context.Canceled, "cancelled"},
		{fmt.Errorf("write: %w", syscall.ENOSPC), "disk_full"},
		{errors.New("decrypt message failed"), "bad_code"},
		{errors.New("TransferError: transfer rejected"), "rejected"},
		{&net.OpError{Op: "dial", Err: errors.New("refused")}, "network"},
		{errors.New("websocket: bad handshake"), "network"},
		{errors.New("something odd"), "internal"},
	}
	for _, c := range cases {
		if got := Classify(c.err); got != c.want {
			t.Errorf("Classify(%v) = %s, want %s", c.err, got, c.want)
		}
	}
}

func TestWaitAnswer(t *testing.T) {
	dir := t.TempDir()
	go func() {
		time.Sleep(300 * time.Millisecond)
		os.WriteFile(filepath.Join(dir, "answer.tmp"), []byte("accept\n"), 0o644)
		os.Rename(filepath.Join(dir, "answer.tmp"), filepath.Join(dir, "answer"))
	}()
	ok, err := WaitAnswer(context.Background(), dir)
	if !ok || err != nil {
		t.Fatalf("got %v %v", ok, err)
	}
	os.WriteFile(filepath.Join(dir, "answer"), []byte("reject"), 0o644)
	if ok, err := WaitAnswer(context.Background(), dir); ok || err != nil {
		t.Fatalf("reject: got %v %v", ok, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := WaitAnswer(ctx, t.TempDir()); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: got %v", err)
	}
}
