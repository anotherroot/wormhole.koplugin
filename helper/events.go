package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Event is one line of output for the KOReader plugin.
type Event struct {
	Ev    string `json:"ev"`
	Code  string `json:"code,omitempty"`
	Kind  string `json:"kind,omitempty"`
	Name  string `json:"name,omitempty"`
	Bytes int64  `json:"bytes,omitempty"`
	Files int    `json:"files,omitempty"`
	Done  int64  `json:"done,omitempty"`
	Total int64  `json:"total,omitempty"`
	Text  string `json:"text,omitempty"`
	Path  string `json:"path,omitempty"`
	Msg   string `json:"msg,omitempty"`
}

// Emitter writes events as JSON lines, one Write per line, so a reader never
// sees half a line followed by another event.
type Emitter struct {
	mu           sync.Mutex
	w            io.Writer
	lastProgress time.Time
}

func NewEmitter(w io.Writer) *Emitter { return &Emitter{w: w} }

func (e *Emitter) Emit(ev Event) {
	e.mu.Lock()
	defer e.mu.Unlock()
	b, _ := json.Marshal(ev)
	e.w.Write(append(b, '\n'))
}

// Progress emits at most 4 progress events a second, plus always the last one.
func (e *Emitter) Progress(done, total int64) {
	e.mu.Lock()
	now := time.Now()
	skip := done < total && now.Sub(e.lastProgress) < 250*time.Millisecond
	if !skip {
		e.lastProgress = now
	}
	e.mu.Unlock()
	if !skip {
		e.Emit(Event{Ev: "progress", Done: done, Total: total})
	}
}

func (e *Emitter) Error(err error) {
	e.Emit(Event{Ev: "error", Kind: Classify(err), Msg: err.Error()})
}

// Classify maps an error to one of the kinds the plugin knows:
// bad_code, rejected, network, disk_full, cancelled, internal.
func Classify(err error) string {
	msg := err.Error()
	var netErr net.Error
	switch {
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case errors.Is(err, syscall.ENOSPC):
		return "disk_full"
	case strings.Contains(msg, "decrypt message failed"):
		return "bad_code"
	case strings.Contains(msg, "TransferError"), strings.Contains(msg, "rejected"):
		return "rejected"
	case errors.As(err, &netErr),
		strings.Contains(msg, "dial"), strings.Contains(msg, "connection refused"),
		strings.Contains(msg, "no such host"), strings.Contains(msg, "websocket"),
		strings.Contains(msg, "failed to establish connection"):
		return "network"
	}
	return "internal"
}
