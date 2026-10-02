package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// CleanName reduces a name sent by the other side to a safe base name:
// no directories, no leading dots, FAT-safe characters, a length that leaves
// room for ".partial-" and " (2)", never empty.
func CleanName(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	name = filepath.Base(name)
	name = strings.TrimLeft(fatSafe(name), ". ")
	if name == "" || name == "/" {
		return "received"
	}
	return limitBytes(name, maxNameBytes)
}

// maxNameBytes keeps ".partial-" + name + " (99)" + ".zip" within FAT's 255.
const maxNameBytes = 200

// fatSafe replaces characters FAT (the Kobo's storage) refuses with "_" and
// drops trailing dots and spaces, which FAT silently strips.
func fatSafe(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || strings.ContainsRune(`:*?"<>|\\`, r) {
			return '_'
		}
		return r
	}, s)
	return strings.TrimRight(s, ". ")
}

// limitBytes shortens the part before the extension to max bytes, cutting at
// a character boundary.
func limitBytes(name string, max int) string {
	ext := filepath.Ext(name)
	if len(ext) > 20 {
		ext = ""
	}
	stem := name[:len(name)-len(ext)]
	if len(stem) <= max {
		return name
	}
	n := max
	for n > 0 && !utf8.RuneStart(stem[n]) {
		n--
	}
	return stem[:n] + ext
}

// UniquePath returns dir/name, or dir/"stem (2)ext", "(3)", … if taken.
// Folders get the number at the end: "Photos (2)".
func UniquePath(dir, name string, isDir bool) string {
	p := filepath.Join(dir, name)
	if !exists(p) {
		return p
	}
	stem, ext := name, ""
	if !isDir {
		ext = filepath.Ext(name)
		stem = strings.TrimSuffix(name, ext)
	}
	for i := 2; ; i++ {
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if !exists(p) {
			return p
		}
	}
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// SaveFile copies r into dir under the cleaned name. It writes to
// ".partial-<name>" first and renames only after the last byte; on any
// error the partial file is removed. Returns the final path.
func SaveFile(dir, name string, r io.Reader) (string, error) {
	name = CleanName(name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	partial := filepath.Join(dir, ".partial-"+name)
	f, err := os.Create(partial)
	if err != nil {
		return "", err
	}
	_, err = io.Copy(f, r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(partial)
		return "", err
	}
	final := UniquePath(dir, name, false)
	if err := os.Rename(partial, final); err != nil {
		os.Remove(partial)
		return "", err
	}
	return final, nil
}

var errZipEscape = errors.New("zip entry outside the folder")

// SaveDir reads a zip from r and unpacks it into dir/<name>/ (or
// "<name> (2)" …). It unpacks into ".partial-<name>/" first; any entry that
// would land outside that folder fails the whole transfer. On error
// everything partial is removed. Returns the final folder path.
func SaveDir(ctx context.Context, dir, name string, r io.Reader) (string, error) {
	name = CleanName(name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	zipPath := filepath.Join(dir, ".partial-"+name+".zip")
	partial := filepath.Join(dir, ".partial-"+name)
	cleanup := func() { os.Remove(zipPath); os.RemoveAll(partial) }
	cleanup() // leftovers of a helper that was killed while unpacking

	zf, err := os.Create(zipPath)
	if err != nil {
		return "", err
	}
	_, err = io.Copy(zf, r)
	if cerr := zf.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = unzip(ctx, zipPath, partial)
	}
	os.Remove(zipPath)
	if err != nil {
		cleanup()
		return "", err
	}
	final := UniquePath(dir, name, true)
	if err := os.Rename(partial, final); err != nil {
		cleanup()
		return "", err
	}
	return final, nil
}

func unzip(ctx context.Context, zipPath, dest string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	for _, f := range zr.File {
		if err := ctx.Err(); err != nil {
			return err
		}
		target := filepath.Join(dest, f.Name) // Join cleans "..": check the result
		if !strings.HasPrefix(target, dest+string(os.PathSeparator)) {
			return fmt.Errorf("%w: %s", errZipEscape, f.Name)
		}
		target = safeTarget(dest, target)
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := extractOne(ctx, f, target); err != nil {
			return err
		}
	}
	return nil
}

func extractOne(ctx context.Context, f *zip.File, target string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, cancelReader{ctx, rc})
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

// cancelReader stops a local copy (a big file being unpacked) on cancel.
type cancelReader struct {
	ctx context.Context
	r   io.Reader
}

func (c cancelReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}

// safeTarget makes every part of a path inside dest FAT-safe.
func safeTarget(dest, target string) string {
	rel, err := filepath.Rel(dest, target)
	if err != nil {
		return target
	}
	parts := strings.Split(rel, string(os.PathSeparator))
	for i, p := range parts {
		if parts[i] = fatSafe(p); parts[i] == "" {
			parts[i] = "_"
		}
	}
	return filepath.Join(append([]string{dest}, parts...)...)
}
