package app

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"serpx/installer/internal/backup"
)

func TestFindPayload(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "bin"), 0o755)
	os.MkdirAll(filepath.Join(root, "src"), 0o755)
	os.MkdirAll(filepath.Join(root, "installer/dist"), 0o755)
	got, err := findPayload("", filepath.Join(root, "installer/dist/serp-installer"), "", "", backup.Identity{})
	if err != nil || got != root {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := findPayload("", "", t.TempDir(), "", backup.Identity{}); err == nil {
		t.Fatal("no payload must be an error")
	}
	if _, err := findPayload(filepath.Join(root, "nope"), "", "", "", backup.Identity{}); err == nil {
		t.Fatal("missing payload must be an error")
	}
}

func TestUnpackPayloadArchive(t *testing.T) {
	var raw bytes.Buffer
	tw := tarWriter(&raw)
	tw("serp-x-1/bin/serpantinum", "x")
	tw("serp-x-1/src/a.txt", "y")
	arc := filepath.Join(t.TempDir(), "p.tar.zst")
	os.WriteFile(arc, raw.Bytes(), 0o600)
	got, err := findPayload(arc, "", "", filepath.Join(t.TempDir(), "u"), backup.Identity{})
	if err != nil || !strings.HasSuffix(got, "serp-x-1") {
		t.Fatalf("%q %v", got, err)
	}
	var bad bytes.Buffer
	tarWriter(&bad)("../evil", "z")
	os.WriteFile(arc, bad.Bytes(), 0o600)
	if _, err := findPayload(arc, "", "", filepath.Join(t.TempDir(), "u"), backup.Identity{}); err == nil {
		t.Fatal("unsafe path must be refused")
	}
}
