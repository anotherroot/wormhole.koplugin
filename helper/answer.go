package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// WaitAnswer polls controlDir/answer every 200 ms until it says "accept" or
// "reject" (the plugin writes answer.tmp, then renames it). Returns true for
// accept. Returns ctx.Err() if cancelled first.
func WaitAnswer(ctx context.Context, controlDir string) (bool, error) {
	p := filepath.Join(controlDir, "answer")
	t := time.NewTicker(200 * time.Millisecond)
	defer t.Stop()
	for {
		if b, err := os.ReadFile(p); err == nil {
			switch strings.TrimSpace(string(b)) {
			case "accept":
				return true, nil
			case "reject":
				return false, nil
			}
		}
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-t.C:
		}
	}
}
