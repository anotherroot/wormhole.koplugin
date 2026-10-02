package main

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// CleanName reduces a name sent by the other side to a safe base name:
// no directories, no leading dots, never empty.
func CleanName(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	name = filepath.Base(name)
	name = strings.TrimLeft(name, ".")
	name = strings.TrimSpace(name)
	if name == "" || name == "/" {
		return "received"
	}
	return name
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
func SaveDir(dir, name string, r io.Reader) (string, error) {
	name = CleanName(name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	zipPath := filepath.Join(dir, ".partial-"+name+".zip")
	partial := filepath.Join(dir, ".partial-"+name)
	cleanup := func() { os.Remove(zipPath); os.RemoveAll(partial) }

	zf, err := os.Create(zipPath)
	if err != nil {
		return "", err
	}
	_, err = io.Copy(zf, r)
	if cerr := zf.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = unzip(zipPath, partial)
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

func unzip(zipPath, dest string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	for _, f := range zr.File {
		target := filepath.Join(dest, f.Name) // Join cleans "..": check the result
		if !strings.HasPrefix(target, dest+string(os.PathSeparator)) {
			return fmt.Errorf("%w: %s", errZipEscape, f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := extractOne(f, target); err != nil {
			return err
		}
	}
	return nil
}

func extractOne(f *zip.File, target string) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, rc)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}
