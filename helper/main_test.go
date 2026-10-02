package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/psanford/wormhole-william/wormhole"
)

func TestUseTmpDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "cache", "wormhole")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	// A temp zip left by a helper that was killed while zipping a folder.
	os.WriteFile(filepath.Join(dir, "wormhole-william-dir123456"), []byte("stale"), 0o644)
	os.WriteFile(filepath.Join(dir, "keep.txt"), []byte("not ours"), 0o644)
	t.Setenv("TMPDIR", "/tmp")

	if err := useTmpDir(dir); err != nil {
		t.Fatal(err)
	}
	if os.TempDir() != dir {
		t.Fatalf("TempDir = %s, want %s", os.TempDir(), dir)
	}
	if _, err := os.Stat(filepath.Join(dir, "wormhole-william-dir123456")); err == nil {
		t.Fatal("stale temp zip not removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "keep.txt")); err != nil {
		t.Fatal("removed a file that isn't ours")
	}
}

func TestUseTmpDirCreatesTheFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "new", "wormhole")
	t.Setenv("TMPDIR", "/tmp")
	if err := useTmpDir(dir); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		t.Fatalf("folder not created: %v", err)
	}
}

func TestWatchPIDCancelsWhenTheProcessIsGone(t *testing.T) {
	cmd := exec.Command("sleep", "0.3") // stands in for KOReader
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go watchPID(ctx, cancel, cmd.Process.Pid, 50*time.Millisecond)

	select {
	case <-ctx.Done():
		t.Fatal("cancelled while the process was still running")
	case <-time.After(100 * time.Millisecond):
	}
	cmd.Wait() // it exits and is reaped
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("not cancelled after the process was gone")
	}
}

func TestRunReceiveNeedsExactlyOneCodeFlag(t *testing.T) {
	d := t.TempDir()
	for _, args := range [][]string{
		{"receive", "--control", d, "--dir", d},
		{"receive", "--control", d, "--dir", d, "--code", "7-a-b", "--new-code"},
	} {
		if got := run(args, NewEmitter(io.Discard)); got != 2 {
			t.Fatalf("run(%v) = %d, want 2 (usage)", args, got)
		}
	}
}

func TestRunReceiveNewCode(t *testing.T) {
	cs, _ := testClients(t)
	save, control := t.TempDir(), t.TempDir()
	rcv := start(func(em *Emitter) error {
		if got := run([]string{"receive", "--control", control, "--rendezvous", cs.RendezvousURL,
			"--new-code", "--dir", save}, em); got != 0 {
			return fmt.Errorf("exit %d", got)
		}
		return nil
	})
	code := rcv.log.waitFor(t, "code").Code
	snd := start(func(em *Emitter) error {
		_, ch, err := cs.SendText(context.Background(), "hello", wormhole.WithCode(code))
		return waitSent(context.Background(), em, code, ch, err)
	})
	if err := rcv.wait(t); err != nil {
		t.Fatal(err)
	}
	if got := rcv.log.waitFor(t, "text").Text; got != "hello" {
		t.Fatalf("text %q", got)
	}
	if err := snd.wait(t); err != nil {
		t.Fatalf("sender: %v", err)
	}
}
