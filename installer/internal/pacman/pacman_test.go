package pacman

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSumDownloadSizes(t *testing.T) {
	if got := SumDownloadSizes(fixture(t, "sp.txt")); got != 1048576+2097152+9830400 {
		t.Fatalf("got %d", got)
	}
	if SumDownloadSizes("") != 0 {
		t.Fatal("empty")
	}
}

func TestParseProgress(t *testing.T) {
	var got []Progress
	for _, l := range splitLines(fixture(t, "install.txt")) {
		if p, ok := ParseProgress(l); ok {
			got = append(got, p)
		}
	}
	want := []Progress{
		{PhaseDownload, "kitty-0.35.2-1-x86_64", 0, 0, 100},
		{PhaseDownload, "cava-0.10.2-1-x86_64", 0, 0, 16},
		{PhaseInstall, "cava", 1, 3, -1},
		{PhaseInstall, "kitty", 2, 3, -1},
		{PhaseInstall, "zbar", 3, 3, -1},
		{PhaseRemove, "quickshell-git", 1, 1, -1},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got  %+v\nwant %+v", got, want)
	}
}

func splitLines(s string) []string { return strings.Split(s, "\n") }

func TestMissingAddedLines(t *testing.T) {
	if !reflect.DeepEqual(Missing("kitty\n\nerror: x\nfoo\n"), []string{"kitty", "foo"}) {
		t.Fatal("missing")
	}
	if !reflect.DeepEqual(Added([]string{"a", "b"}, []string{"a", "c", "b", "d"}), []string{"c", "d"}) {
		t.Fatal("added")
	}
}

func TestLock(t *testing.T) {
	dir := t.TempDir()
	lock := filepath.Join(dir, "db.lck")
	if s, _ := CheckLock(lock, func() bool { return true }); s != LockNone {
		t.Fatal("none")
	}
	os.WriteFile(lock, nil, 0o644)
	if s, _ := CheckLock(lock, func() bool { return true }); s != LockBusy {
		t.Fatal("busy")
	}
	if s, _ := CheckLock(lock, func() bool { return false }); s != LockStale {
		t.Fatal("stale")
	}
}

func TestKeyringAndRequiredBy(t *testing.T) {
	qi := fixture(t, "qi-keyring.txt")
	now := time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC)
	if KeyringStale(qi, now, 30*24*time.Hour) {
		t.Fatal("19 days old is fresh")
	}
	if !KeyringStale(qi, now.AddDate(0, 0, 20), 30*24*time.Hour) {
		t.Fatal("39 days old is stale")
	}
	if !KeyringStale("garbage", now, time.Hour) {
		t.Fatal("unknown date counts as stale")
	}
	if !reflect.DeepEqual(RequiredBy(qi), []string{"pacman"}) || RequiredBy(fixture(t, "qi-free.txt")) != nil {
		t.Fatal("required by")
	}
}
