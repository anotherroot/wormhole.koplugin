package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/psanford/wormhole-william/rendezvous/rendezvousservertest"
	"github.com/psanford/wormhole-william/wormhole"
)

// eventLog is an io.Writer for an Emitter that keeps the parsed events.
type eventLog struct {
	mu     sync.Mutex
	events []Event
}

func (l *eventLog) Write(p []byte) (int, error) {
	var ev Event
	if err := json.Unmarshal(p, &ev); err != nil {
		panic(err)
	}
	l.mu.Lock()
	l.events = append(l.events, ev)
	l.mu.Unlock()
	return len(p), nil
}

// waitFor returns the first event of type ev, waiting up to 10 s.
func (l *eventLog) waitFor(t *testing.T, ev string) Event {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		l.mu.Lock()
		for _, e := range l.events {
			if e.Ev == ev {
				l.mu.Unlock()
				return e
			}
		}
		l.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no %q event; got %+v", ev, l.events)
	return Event{}
}

func (l *eventLog) last() Event {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.events[len(l.events)-1]
}

func testClients(t *testing.T) (*wormhole.Client, *wormhole.Client) {
	rs := rendezvousservertest.NewServer()
	t.Cleanup(rs.Close)
	wormhole.DefaultTransitRelayAddress = "" // direct connections on localhost
	return &wormhole.Client{RendezvousURL: rs.WebSocketURL()},
		&wormhole.Client{RendezvousURL: rs.WebSocketURL()}
}

type side struct {
	log  *eventLog
	errc chan error
}

func start(f func(em *Emitter) error) side {
	s := side{log: &eventLog{}, errc: make(chan error, 1)}
	em := NewEmitter(s.log)
	go func() {
		err := f(em)
		if err != nil && err != errAlreadyReported {
			em.Error(err)
		}
		s.errc <- err
	}()
	return s
}

func (s side) wait(t *testing.T) error {
	t.Helper()
	select {
	case err := <-s.errc:
		return err
	case <-time.After(15 * time.Second):
		t.Fatal("timed out")
		return nil
	}
}

func answer(t *testing.T, dir, word string) {
	os.WriteFile(filepath.Join(dir, "answer.tmp"), []byte(word), 0o644)
	if err := os.Rename(filepath.Join(dir, "answer.tmp"), filepath.Join(dir, "answer")); err != nil {
		t.Fatal(err)
	}
}

func TestRoundTripText(t *testing.T) {
	cs, cr := testClients(t)
	ctx := context.Background()
	snd := start(func(em *Emitter) error { return SendText(ctx, cs, em, weirdText) })
	code := snd.log.waitFor(t, "code").Code
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, code, t.TempDir(), t.TempDir()) })
	if err := rcv.wait(t); err != nil {
		t.Fatal(err)
	}
	if got := rcv.log.waitFor(t, "text").Text; got != weirdText {
		t.Fatalf("text %q", got)
	}
	if err := snd.wait(t); err != nil || snd.log.last().Ev != "done" {
		t.Fatalf("sender: %v %+v", err, snd.log.last())
	}
}

func TestRoundTripFileAcceptAndClash(t *testing.T) {
	cs, cr := testClients(t)
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "Dune.epub")
	body := strings.Repeat("spice ", 100000)
	os.WriteFile(src, []byte(body), 0o644)
	save, control := t.TempDir(), t.TempDir()
	os.WriteFile(filepath.Join(save, "Dune.epub"), []byte("older"), 0o644)

	snd := start(func(em *Emitter) error { return SendFile(ctx, cs, em, src) })
	code := snd.log.waitFor(t, "code").Code
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, code, save, control) })
	offer := rcv.log.waitFor(t, "offer")
	if offer.Kind != "file" || offer.Name != "Dune.epub" || offer.Bytes != int64(len(body)) {
		t.Fatalf("offer %+v", offer)
	}
	answer(t, control, "accept")
	if err := rcv.wait(t); err != nil {
		t.Fatal(err)
	}
	saved := rcv.log.waitFor(t, "saved").Path
	if saved != filepath.Join(save, "Dune (2).epub") {
		t.Fatalf("saved to %s", saved)
	}
	if b, _ := os.ReadFile(saved); string(b) != body {
		t.Fatal("content differs")
	}
	if p := rcv.log.waitFor(t, "progress"); p.Total != int64(len(body)) {
		t.Fatalf("progress %+v", p)
	}
	if err := snd.wait(t); err != nil {
		t.Fatalf("sender: %v", err)
	}
	if p := snd.log.waitFor(t, "progress"); p.Total == 0 {
		t.Fatalf("sender progress %+v", p)
	}
}

func TestRoundTripFolder(t *testing.T) {
	cs, cr := testClients(t)
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "Books")
	os.MkdirAll(filepath.Join(src, "sub"), 0o755)
	os.WriteFile(filepath.Join(src, "a.epub"), []byte("A"), 0o644)
	os.WriteFile(filepath.Join(src, "sub", "b.epub"), []byte("B"), 0o644)
	save, control := t.TempDir(), t.TempDir()

	snd := start(func(em *Emitter) error { return SendFiles(ctx, cs, em, "Books", []string{src}) })
	code := snd.log.waitFor(t, "code").Code
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, code, save, control) })
	offer := rcv.log.waitFor(t, "offer")
	if offer.Kind != "dir" || offer.Name != "Books" || offer.Files != 2 {
		t.Fatalf("offer %+v", offer)
	}
	answer(t, control, "accept")
	if err := rcv.wait(t); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(save, "Books", "sub", "b.epub")); string(b) != "B" {
		t.Fatalf("sub/b.epub = %q", b)
	}
	if err := snd.wait(t); err != nil {
		t.Fatalf("sender: %v", err)
	}
}

func TestReject(t *testing.T) {
	cs, cr := testClients(t)
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "Dune.epub")
	os.WriteFile(src, []byte("spice"), 0o644)
	save, control := t.TempDir(), t.TempDir()

	snd := start(func(em *Emitter) error { return SendFile(ctx, cs, em, src) })
	code := snd.log.waitFor(t, "code").Code
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, code, save, control) })
	rcv.log.waitFor(t, "offer")
	answer(t, control, "reject")
	rcv.wait(t)
	if e := rcv.log.last(); e.Ev != "error" || e.Kind != "rejected" {
		t.Fatalf("receiver last %+v", e)
	}
	snd.wait(t)
	if e := snd.log.last(); e.Ev != "error" || e.Kind != "rejected" {
		t.Fatalf("sender last %+v", e)
	}
	if entries, _ := os.ReadDir(save); len(entries) != 0 {
		t.Fatalf("saved something: %v", entries)
	}
}

func TestBadCode(t *testing.T) {
	cs, cr := testClients(t)
	ctx := context.Background()
	snd := start(func(em *Emitter) error { return SendText(ctx, cs, em, "secret") })
	code := snd.log.waitFor(t, "code").Code
	nameplate := strings.SplitN(code, "-", 2)[0]
	rcv := start(func(em *Emitter) error {
		return Receive(ctx, cr, em, nameplate+"-wrong-words", t.TempDir(), t.TempDir())
	})
	rcv.wait(t)
	if e := rcv.log.last(); e.Ev != "error" || e.Kind != "bad_code" {
		t.Fatalf("receiver last %+v", e)
	}
	snd.wait(t)
	if e := snd.log.last(); e.Ev != "error" || e.Kind != "bad_code" {
		t.Fatalf("sender last %+v", e)
	}
}

func TestCancelWhileWaitingForReceiver(t *testing.T) {
	cs, _ := testClients(t)
	ctx, cancel := context.WithCancel(context.Background())
	snd := start(func(em *Emitter) error { return SendText(ctx, cs, em, "never read") })
	snd.log.waitFor(t, "code")
	cancel()
	snd.wait(t)
	if e := snd.log.last(); e.Ev != "error" || e.Kind != "cancelled" {
		t.Fatalf("last %+v", e)
	}
}

func TestDirEntries(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "a.epub"), []byte("A"), 0o644)
	os.MkdirAll(filepath.Join(d, "x"), 0o755)
	os.WriteFile(filepath.Join(d, "x", "a.epub"), []byte("A2"), 0o644)
	entries, err := DirEntries("Wormhole files", []string{filepath.Join(d, "a.epub"), filepath.Join(d, "x", "a.epub")})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.Path)
	}
	want := "Wormhole files/a.epub,Wormhole files/a (2).epub"
	if strings.Join(got, ",") != want {
		t.Fatalf("got %v", got)
	}
	if _, err := DirEntries("Empty", []string{t.TempDir()}); err == nil {
		t.Fatal("empty folder: want error")
	}
}

// Shell and JSON specials, newlines and non-ASCII must arrive unchanged.
const weirdText = "¿Dónde está? it's \"quoted\" $(echo no) `no` \\n\nline 2 📚"

func TestCancelWhileReceiverWaitsForUnknownCode(t *testing.T) {
	_, cr := testClients(t)
	ctx, cancel := context.WithCancel(context.Background())
	save := t.TempDir()
	// A mistyped number: nobody is on nameplate 999, so the server just waits.
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, "999-nobody-here", save, t.TempDir()) })
	time.Sleep(300 * time.Millisecond)
	cancel()
	rcv.wait(t)
	if e := rcv.log.last(); e.Ev != "error" || e.Kind != "cancelled" {
		t.Fatalf("last %+v", e)
	}
}

// slowReader makes a send take long enough to cancel the receiver mid-way.
type slowReader struct{ *strings.Reader }

func (s slowReader) Read(p []byte) (int, error) {
	time.Sleep(20 * time.Millisecond)
	if len(p) > 4096 {
		p = p[:4096]
	}
	return s.Reader.Read(p)
}

func TestCancelDuringReceiveRemovesPartial(t *testing.T) {
	cs, cr := testClients(t)
	code, _, err := cs.SendFile(context.Background(), "Slow.epub",
		slowReader{strings.NewReader(strings.Repeat("x", 1<<20))})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	save, control := t.TempDir(), t.TempDir()
	rcv := start(func(em *Emitter) error { return Receive(ctx, cr, em, code, save, control) })
	rcv.log.waitFor(t, "offer")
	answer(t, control, "accept")
	rcv.log.waitFor(t, "progress")
	cancel()
	rcv.wait(t)
	if e := rcv.log.last(); e.Ev != "error" || e.Kind != "cancelled" {
		t.Fatalf("last %+v", e)
	}
	if entries, _ := os.ReadDir(save); len(entries) != 0 {
		t.Fatalf("left behind: %v", entries)
	}
}
