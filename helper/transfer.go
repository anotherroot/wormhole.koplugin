package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/psanford/wormhole-william/wormhole"
)

// waitSent emits the code, then waits for the transfer to finish.
func waitSent(ctx context.Context, em *Emitter, code string, ch chan wormhole.SendResult, err error) error {
	if err != nil {
		return err
	}
	em.Emit(Event{Ev: "code", Code: code})
	select {
	case <-ctx.Done():
		return ctx.Err()
	case res := <-ch:
		if !res.OK {
			if res.Error == nil {
				return errors.New("transfer failed")
			}
			return res.Error
		}
	}
	em.Emit(Event{Ev: "done"})
	return nil
}

func SendText(ctx context.Context, c *wormhole.Client, em *Emitter, text string) error {
	code, ch, err := c.SendText(ctx, text)
	return waitSent(ctx, em, code, ch, err)
}

func SendFile(ctx context.Context, c *wormhole.Client, em *Emitter, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	code, ch, err := c.SendFile(ctx, filepath.Base(path), f, wormhole.WithProgress(em.Progress))
	return waitSent(ctx, em, code, ch, err)
}

func SendFiles(ctx context.Context, c *wormhole.Client, em *Emitter, name string, paths []string) error {
	name = CleanName(name)
	entries, err := DirEntries(name, paths)
	if err != nil {
		return err
	}
	code, ch, err := c.SendDirectory(ctx, name, entries, wormhole.WithProgress(em.Progress))
	return waitSent(ctx, em, code, ch, err)
}

// DirEntries lists the files to send as one folder called name.
// One folder path: its contents go directly into name/.
// Otherwise every path goes into name/ under its own base name
// (a clash gets " (2)", " (3)", …).
func DirEntries(name string, paths []string) ([]wormhole.DirectoryEntry, error) {
	var entries []wormhole.DirectoryEntry
	add := func(abs, rel string, mode fs.FileMode) {
		entries = append(entries, wormhole.DirectoryEntry{
			Path:   name + "/" + filepath.ToSlash(rel),
			Mode:   mode,
			Reader: func() (io.ReadCloser, error) { return os.Open(abs) },
		})
	}
	walk := func(root, prefix string) error {
		return filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.Type().IsRegular() {
				return nil // folders are implied; skip links and devices
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			rel, _ := filepath.Rel(root, p)
			add(p, filepath.Join(prefix, rel), info.Mode().Perm())
			return nil
		})
	}

	if len(paths) == 1 {
		if st, err := os.Stat(paths[0]); err == nil && st.IsDir() {
			if err := walk(paths[0], ""); err != nil {
				return nil, err
			}
			if len(entries) == 0 {
				return nil, fmt.Errorf("folder %s has no files", paths[0])
			}
			return entries, nil
		}
	}

	used := map[string]bool{}
	for _, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		base := filepath.Base(p)
		top := base
		for i := 2; used[top]; i++ {
			ext := ""
			if !st.IsDir() {
				ext = filepath.Ext(base)
			}
			top = fmt.Sprintf("%s (%d)%s", base[:len(base)-len(ext)], i, ext)
		}
		used[top] = true
		if st.IsDir() {
			if err := walk(p, top); err != nil {
				return nil, err
			}
		} else {
			add(p, top, st.Mode().Perm())
		}
	}
	if len(entries) == 0 {
		return nil, errors.New("no files to send")
	}
	return entries, nil
}

type countingReader struct {
	r     io.Reader
	done  int64
	total int64
	em    *Emitter
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.done += int64(n)
	if n > 0 {
		c.em.Progress(c.done, c.total)
	}
	return n, err
}

func Receive(ctx context.Context, c *wormhole.Client, em *Emitter, code, saveDir, controlDir string) error {
	msg, err := c.Receive(ctx, code)
	if err != nil {
		return err
	}
	switch msg.Type {
	case wormhole.TransferText:
		b, err := io.ReadAll(msg)
		if err != nil {
			return err
		}
		em.Emit(Event{Ev: "text", Text: string(b)})
		em.Emit(Event{Ev: "done"})
		return nil
	case wormhole.TransferFile, wormhole.TransferDirectory:
	default:
		return fmt.Errorf("unknown transfer type %v", msg.Type)
	}

	isDir := msg.Type == wormhole.TransferDirectory
	offer := Event{Ev: "offer", Kind: "file", Name: CleanName(msg.Name), Bytes: msg.TransferBytes64}
	if isDir {
		offer.Kind, offer.Bytes, offer.Files = "dir", msg.UncompressedBytes64, msg.FileCount
	}
	em.Emit(offer)

	ok, err := WaitAnswer(ctx, controlDir)
	if err != nil {
		return err
	}
	if !ok {
		msg.Reject()
		em.Emit(Event{Ev: "error", Kind: "rejected", Msg: "you rejected the transfer"})
		return errAlreadyReported
	}

	r := &countingReader{r: msg, total: msg.TransferBytes64, em: em}
	var path string
	if isDir {
		path, err = SaveDir(saveDir, msg.Name, r)
	} else {
		path, err = SaveFile(saveDir, msg.Name, r)
	}
	if err != nil {
		return err
	}
	em.Emit(Event{Ev: "saved", Path: path})
	em.Emit(Event{Ev: "done"})
	return nil
}

// errAlreadyReported: the error event was emitted already; exit non-zero quietly.
var errAlreadyReported = errors.New("already reported")
