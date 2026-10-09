package journal

import (
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAppendRead(t *testing.T) {
	dir := t.TempDir()
	j, err := Open(filepath.Join(dir, "st"), "r1")
	if err != nil {
		t.Fatal(err)
	}
	j.Append("pkg.repo", EvStart, nil)
	j.Append("pkg.repo", EvDone, map[string]any{"n": 3, "gemini_key": "AIza-SECRET"})
	j.Append("", EvFinish, nil)
	j.Close()
	raw, _ := os.ReadFile(filepath.Join(dir, "st", FileJournal))
	if strings.Contains(string(raw), "AIza-SECRET") {
		t.Fatal("secret leaked into journal")
	}
	fi, _ := os.Stat(filepath.Join(dir, "st", FileJournal))
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode())
	}
	di, _ := os.Stat(filepath.Join(dir, "st"))
	if di.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %v", di.Mode())
	}
	e, err := Read(filepath.Join(dir, "st", FileJournal))
	if err != nil || len(e) != 3 || e[2].Seq != 3 {
		t.Fatalf("%v %v", e, err)
	}
	if States(e)["pkg.repo"] != EvDone || !Finished(e) {
		t.Fatal("state")
	}
}

func TestTornTailAndBadCRC(t *testing.T) {
	cases := map[string]func(good []byte) []byte{
		"torn mid-line": func(g []byte) []byte {
			return append(g, []byte(`{"v":1,"seq":4,"run":"r","ts":"x","step":"a","ev":"sta`)...)
		},
		"bad crc": func(g []byte) []byte {
			return append(g, []byte(`{"v":1,"seq":4,"run":"r","ts":"x","step":"a","ev":"start","crc":"00000000"}`+"\n")...)
		},
		"no newline but valid": func(g []byte) []byte {
			// a full line lacking the final \n is also discarded
			l := g[:len(g)-1]
			i := strings.LastIndexByte(string(l), '\n')
			return append(append([]byte{}, g...), l[i+1:]...)
		},
		"garbage": func(g []byte) []byte { return append(g, 0, 0, 0, '\n') },
	}
	for name, mut := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			j, _ := Open(dir, "r")
			for i := 0; i < 3; i++ {
				j.Append(fmt.Sprint("s", i), EvDone, nil)
			}
			j.Close()
			p := filepath.Join(dir, FileJournal)
			g, _ := os.ReadFile(p)
			os.WriteFile(p, mut(g), 0o600)

			j2, err := Open(dir, "r2")
			if err != nil {
				t.Fatal(err)
			}
			if err := j2.Append("s3", EvDone, nil); err != nil {
				t.Fatal(err)
			}
			j2.Close()
			e, _ := Read(p)
			if len(e) != 4 || e[3].Seq != 4 || e[3].Step != "s3" {
				t.Fatalf("got %+v", e)
			}
			after, _ := os.ReadFile(p)
			if !strings.HasPrefix(string(after), string(g)) {
				t.Fatal("good prefix altered")
			}
		})
	}
}

func TestCorruptMiddleStopsThere(t *testing.T) {
	dir := t.TempDir()
	j, _ := Open(dir, "r")
	for i := 0; i < 5; i++ {
		j.Append(fmt.Sprint("s", i), EvDone, nil)
	}
	j.Close()
	p := filepath.Join(dir, FileJournal)
	b, _ := os.ReadFile(p)
	lines := strings.Split(string(b), "\n")
	lines[2] = strings.Replace(lines[2], "s2", "sX", 1)
	os.WriteFile(p, []byte(strings.Join(lines, "\n")), 0o600)
	e, err := Repair(p)
	if err != nil || len(e) != 2 {
		t.Fatalf("%d %v", len(e), err)
	}
}

// Child process: writes 1000 records until killed.
func TestMain(m *testing.M) {
	if d := os.Getenv("JOURNAL_CHILD_DIR"); d != "" {
		j, err := Open(d, "child")
		if err != nil {
			os.Exit(2)
		}
		for i := 0; i < 1000; i++ {
			j.Append(fmt.Sprintf("step.%d", i), EvDone, map[string]any{"pad": strings.Repeat("x", 200)})
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestKillDuringWrites(t *testing.T) {
	exe, _ := os.Executable()
	for round := 0; round < 8; round++ {
		dir := t.TempDir()
		cmd := exec.Command(exe, "-test.run=XXX_none")
		cmd.Env = append(os.Environ(), "JOURNAL_CHILD_DIR="+dir)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Duration(rand.Intn(40)) * time.Millisecond)
		cmd.Process.Kill()
		cmd.Wait()
		p := filepath.Join(dir, FileJournal)
		e, err := Repair(p)
		if err != nil {
			t.Fatal(err)
		}
		for i, x := range e {
			if x.Seq != i+1 {
				t.Fatalf("round %d: gap at %d: seq %d", round, i, x.Seq)
			}
		}
		// still appendable after repair
		j, err := Open(dir, "again")
		if err != nil {
			t.Fatal(err)
		}
		if err := j.Append("after", EvDone, nil); err != nil {
			t.Fatal(err)
		}
		j.Close()
		e2, _ := Read(p)
		if len(e2) != len(e)+1 {
			t.Fatalf("round %d: %d vs %d", round, len(e2), len(e))
		}
	}
	// And a complete run reads 1000 entries.
	dir := t.TempDir()
	cmd := exec.Command(exe, "-test.run=XXX_none")
	cmd.Env = append(os.Environ(), "JOURNAL_CHILD_DIR="+dir)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	e, _ := Read(filepath.Join(dir, FileJournal))
	if len(e) != 1000 {
		t.Fatalf("%d", len(e))
	}
}

func TestWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, FilePlan)
	if err := WriteJSON(p, map[string]string{"gemini_key": "set"}); err != nil {
		t.Fatal(err)
	}
	if err := WriteJSON(p, map[string]string{"a": "b"}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	if !strings.Contains(string(b), `"a": "b"`) {
		t.Fatal(string(b))
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 {
		t.Fatalf("temp files left: %v", ents)
	}
	// A leftover tmp from a crashed writer must not affect the real file.
	os.WriteFile(p+".tmp.999", []byte("{garbage"), 0o600)
	b2, _ := os.ReadFile(p)
	if string(b2) != string(b) {
		t.Fatal("plan changed")
	}
	// failure leaves the original intact
	if err := WriteAtomic(filepath.Join(dir, "nodir", "x"), []byte("x"), 0o600); err == nil {
		t.Fatal("want error")
	}
}

func TestNeedsResume(t *testing.T) {
	dir := t.TempDir()
	if ok, _ := NeedsResume(dir); ok {
		t.Fatal("no plan")
	}
	WriteJSON(filepath.Join(dir, FilePlan), map[string]int{"n": 1})
	j, _ := Open(dir, "r")
	j.Append("a", EvStart, nil)
	if ok, _ := NeedsResume(dir); !ok {
		t.Fatal("should resume")
	}
	j.Append("", EvFinish, nil)
	j.Close()
	if ok, _ := NeedsResume(dir); ok {
		t.Fatal("finished")
	}
}
