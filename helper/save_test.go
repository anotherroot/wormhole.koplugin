package main

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCleanName(t *testing.T) {
	cases := map[string]string{
		"Dune.epub":          "Dune.epub",
		"../../etc/passwd":   "passwd",
		"a/b/c.epub":         "c.epub",
		`..\..\win.epub`:     "win.epub",
		".hidden":            "hidden",
		"..":                 "received",
		"":                   "received",
		"  spaced name.pdf ": "spaced name.pdf",
	}
	for in, want := range cases {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUniquePath(t *testing.T) {
	dir := t.TempDir()
	if got := UniquePath(dir, "Dune.epub", false); got != filepath.Join(dir, "Dune.epub") {
		t.Fatalf("free name: got %s", got)
	}
	os.WriteFile(filepath.Join(dir, "Dune.epub"), nil, 0o644)
	os.WriteFile(filepath.Join(dir, "Dune (2).epub"), nil, 0o644)
	if got := UniquePath(dir, "Dune.epub", false); got != filepath.Join(dir, "Dune (3).epub") {
		t.Fatalf("taken twice: got %s", got)
	}
	os.Mkdir(filepath.Join(dir, "Photos.v1"), 0o755)
	if got := UniquePath(dir, "Photos.v1", true); got != filepath.Join(dir, "Photos.v1 (2)") {
		t.Fatalf("folder: got %s", got)
	}
}

func TestSaveFileWritesAndNeverOverwrites(t *testing.T) {
	dir := t.TempDir()
	p1, err := SaveFile(dir, "../Dune.epub", strings.NewReader("one"))
	if err != nil || p1 != filepath.Join(dir, "Dune.epub") {
		t.Fatalf("first save: %s %v", p1, err)
	}
	p2, err := SaveFile(dir, "Dune.epub", strings.NewReader("two"))
	if err != nil || p2 != filepath.Join(dir, "Dune (2).epub") {
		t.Fatalf("second save: %s %v", p2, err)
	}
	if b, _ := os.ReadFile(p1); string(b) != "one" {
		t.Fatalf("first file overwritten: %q", b)
	}
	assertNoPartial(t, dir)
}

type failingReader struct{ n int }

func (f *failingReader) Read(p []byte) (int, error) {
	if f.n > 0 {
		f.n--
		return copy(p, "data"), nil
	}
	return 0, errors.New("connection lost")
}

func TestSaveFileRemovesPartialOnError(t *testing.T) {
	dir := t.TempDir()
	if _, err := SaveFile(dir, "Dune.epub", &failingReader{n: 3}); err == nil {
		t.Fatal("want error")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("left behind: %v", entries)
	}
}

func makeZip(t *testing.T, files map[string]string) io.Reader {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, body := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(body))
	}
	zw.Close()
	return &buf
}

func TestSaveDirUnpacks(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "Books"), 0o755)
	p, err := SaveDir(context.Background(), dir, "Books", makeZip(t, map[string]string{"a.epub": "A", "sub/b.epub": "B"}))
	if err != nil || p != filepath.Join(dir, "Books (2)") {
		t.Fatalf("got %s %v", p, err)
	}
	if b, _ := os.ReadFile(filepath.Join(p, "sub", "b.epub")); string(b) != "B" {
		t.Fatalf("sub/b.epub = %q", b)
	}
	assertNoPartial(t, dir)
}

func TestSaveDirRefusesEscape(t *testing.T) {
	dir := t.TempDir()
	for _, evil := range []string{"../evil.txt", "a/../../evil.txt", "/abs/evil.txt"} {
		_, err := SaveDir(context.Background(), dir, "Books", makeZip(t, map[string]string{"ok.txt": "fine", evil: "bad"}))
		if evil == "/abs/evil.txt" {
			// Join("dest", "/abs/evil.txt") stays inside dest: allowed, harmless.
			if err != nil {
				t.Fatalf("%s: %v", evil, err)
			}
			os.RemoveAll(filepath.Join(dir, "Books"))
			continue
		}
		if !errors.Is(err, errZipEscape) {
			t.Fatalf("%s: want errZipEscape, got %v", evil, err)
		}
		if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "evil.txt")); err == nil {
			t.Fatalf("%s: file escaped", evil)
		}
		assertNoPartial(t, dir)
		if exists(filepath.Join(dir, "Books")) {
			t.Fatalf("%s: final folder created", evil)
		}
	}
}

func assertNoPartial(t *testing.T, dir string) {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".partial-") {
			t.Fatalf("partial left behind: %s", e.Name())
		}
	}
}

func TestSaveDirReplacesStalePartial(t *testing.T) {
	dir := t.TempDir()
	// Left behind by a helper that was killed while unpacking.
	os.MkdirAll(filepath.Join(dir, ".partial-Books"), 0o755)
	os.WriteFile(filepath.Join(dir, ".partial-Books", "a.epub"), []byte("old"), 0o644)
	os.WriteFile(filepath.Join(dir, ".partial-Books.zip"), []byte("old zip"), 0o644)
	p, err := SaveDir(context.Background(), dir, "Books", makeZip(t, map[string]string{"a.epub": "A"}))
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(p, "a.epub")); string(b) != "A" {
		t.Fatalf("a.epub = %q", b)
	}
	assertNoPartial(t, dir)
}

func TestSaveDirStopsWhenCancelled(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // e.g. Cancel pressed while a big folder unpacks
	_, err := SaveDir(ctx, dir, "Books", makeZip(t, map[string]string{"a.epub": "A", "b.epub": "B"}))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("left behind: %v", entries)
	}
}

// The Kobo's storage is FAT: these characters make file creation fail.
func TestCleanNameIsFATSafe(t *testing.T) {
	cases := map[string]string{
		"Dune: Messiah.epub":               "Dune_ Messiah.epub",
		`Who Moved My Cheese?.pdf`:         "Who Moved My Cheese_.pdf",
		`a*b"c<d>e|f.txt`:                  "a_b_c_d_e_f.txt",
		"tab\there\x01.epub":               "tab_here_.epub",
		"trailing dots... ":                "trailing dots",
		" .hidden":                         "hidden",
		"ñandú — 📚.epub":                   "ñandú — 📚.epub",
		strings.Repeat("é", 200) + ".epub": strings.Repeat("é", 100) + ".epub",
	}
	for in, want := range cases {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSaveDirMakesEntryNamesFATSafe(t *testing.T) {
	dir := t.TempDir()
	p, err := SaveDir(context.Background(), dir, "Shelf: new?",
		makeZip(t, map[string]string{"Sci-Fi: Best?/A <1>.epub": "A"}))
	if err != nil {
		t.Fatal(err)
	}
	if p != filepath.Join(dir, "Shelf_ new_") {
		t.Fatalf("folder %s", p)
	}
	if b, _ := os.ReadFile(filepath.Join(p, "Sci-Fi_ Best_", "A _1_.epub")); string(b) != "A" {
		t.Fatalf("entry not saved under a FAT-safe name")
	}
}
