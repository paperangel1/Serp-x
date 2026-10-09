package backup

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/fsx"
	"serpx/installer/internal/run"
)

var now = time.Date(2026, 10, 7, 19, 4, 0, 0, time.UTC)

const (
	fakeGemini = "AIzaFAKEgeminiSECRET0123456789abcdefghi"
	fakeToken  = "FAKE-REMNAWAVE-TOKEN-zzz"
	fakePriv   = "FAKE-PRIVATE-KEY-BODY"
	fakeSub    = "https://sub.example.test/FAKESUBSCRIPTION"
	fakeApiKey = "AIzaFAKEinsideSETTINGS000000000000000000"
	fakeHosts  = "FAKE-KNOWN-HOSTS-LINE"
)

func w(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mkHome(t *testing.T) (Roots, string) {
	home := t.TempDir()
	r := Roots{Config: filepath.Join(home, ".config"), State: filepath.Join(home, ".local/state"), Notes: filepath.Join(home, "Notes")}
	c := filepath.Join(r.Config, "serpantinum")
	w(t, c+"/settings.json", `{"general":{"language":"ru","location":"Fake City, 11.1,22.2"},"hotkeys":{"custom":[{"k":"x"}]},"ai":{"proxy":"","apiKey":"`+fakeApiKey+`"},"vpn":{"mode":"all"}}`)
	w(t, c+"/commands/a.cmd.json", `{"id":"a"}`)
	w(t, c+"/commands/b.cmd.json", `{"id":"b"}`)
	w(t, c+"/commands/ignored.txt", "nope")
	w(t, c+"/servers/servers.toml", "[[server]]\nname='s1'\n")
	w(t, c+"/servers/commands.toml", "[x]\n")
	w(t, c+"/servers/id_serp", fakePriv)
	w(t, c+"/servers/id_serp.pub", "ssh-ed25519 FAKEPUB")
	w(t, c+"/servers/known_hosts", fakeHosts)
	w(t, c+"/secrets/gemini_key", fakeGemini)
	w(t, c+"/secrets/remnawave_token", fakeToken)
	w(t, c+"/secrets/vpn_subscription", fakeSub)
	w(t, r.State+"/serpantinum/x_colors.json", `["#fff"]`)
	w(t, r.State+"/serpantinum/vpn-nodes.json", "NODES")
	w(t, r.Notes+"/a.md", "note a")
	w(t, r.Notes+"/sub/b.md", "note b")
	_ = os.Symlink("/etc/passwd", r.Notes+"/link")
	return r, home
}

func compressors(t *testing.T) map[string]Compressor {
	m := map[string]Compressor{"identity": Identity{}}
	if _, err := exec.LookPath("zstd"); err == nil {
		m["zstd"] = Zstd{}
	}
	return m
}

func decompressed(t *testing.T, c Compressor, p string) []byte {
	f, _ := os.Open(p)
	defer f.Close()
	r, err := c.Decompress(f)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestRoundtrip(t *testing.T) {
	for name, comp := range compressors(t) {
		t.Run(name, func(t *testing.T) {
			src, _ := mkHome(t)
			out := t.TempDir()
			arch, err := Export(ExportOptions{Roots: src, Build: "2.2.4-s3", Modules: []string{"core", "servers"}, Host: "my host", Now: now, OutDir: out, Compressor: comp})
			if err != nil {
				t.Fatal(err)
			}
			if filepath.Base(arch) != "serpantinum-backup-my_host-20261007-1904.tar.zst" {
				t.Fatal(arch)
			}
			// no secrets anywhere in the bytes (compressed AND raw tar)
			raw, _ := os.ReadFile(arch)
			plain := decompressed(t, comp, arch)
			for _, s := range []string{fakeGemini, fakeToken, fakePriv, fakeSub, fakeApiKey, fakeHosts, "FAKEPUB", "NODES", "Fake City", "/etc/passwd", "nope"} {
				if bytes.Contains(raw, []byte(s)) || bytes.Contains(plain, []byte(s)) {
					t.Errorf("archive contains %q", s)
				}
			}
			man, err := ReadManifest(arch, comp)
			if err != nil {
				t.Fatal(err)
			}
			if man.Format != 1 || man.Build != "2.2.4-s3" || len(man.SecretsNotIncluded) != 5 {
				t.Fatalf("%+v", man)
			}
			if strings.Join(man.Stripped, ",") != "ai.apiKey,general.location" {
				t.Fatalf("stripped %v", man.Stripped)
			}
			var paths []string
			for _, f := range man.Files {
				paths = append(paths, f.Path)
			}
			want := "data/config/serpantinum/commands/a.cmd.json,data/config/serpantinum/commands/b.cmd.json," +
				"data/config/serpantinum/servers/commands.toml,data/config/serpantinum/servers/servers.toml," +
				"data/config/serpantinum/settings.json,data/notes/a.md,data/notes/sub/b.md,data/state/serpantinum/x_colors.json"
			if strings.Join(paths, ",") != want {
				t.Fatalf("files:\n%v", paths)
			}

			// import into a clean "new" home
			dst := Roots{Config: t.TempDir(), State: t.TempDir(), Notes: t.TempDir()}
			stateDir := t.TempDir()
			fx, err := fsx.New(fsx.Config{Allowed: []string{dst.Config, dst.State, dst.Notes}, StateDir: stateDir, Run: "r1"})
			if err != nil {
				t.Fatal(err)
			}
			fr := run.NewFake()
			res, err := Import(context.Background(), arch, ImportOptions{Roots: dst, FS: fx, Tag: "restore", Modules: []string{"core", "servers"}, Compressor: comp,
				Runner: fr, After: &run.Cmd{Name: "x_keybinds.sh", Args: []string{"generate"}}})
			if err != nil {
				t.Fatal(err)
			}
			if len(res.Restored) != len(man.Files) || len(res.Warnings) != 0 {
				t.Fatalf("%+v", res)
			}
			if got := fr.Calls(); len(got) != 1 || got[0] != "x_keybinds.sh generate" {
				t.Fatalf("calls %v", got)
			}
			// sha256 of each restored file equals the manifest
			for _, f := range man.Files {
				target, _ := dst.toTarget(f.Path)
				b, err := os.ReadFile(target)
				if err != nil {
					t.Fatal(err)
				}
				s := sha256.Sum256(b)
				if hex.EncodeToString(s[:]) != f.SHA256 {
					t.Errorf("sha mismatch %s", f.Path)
				}
			}
			// retype list: modules core+servers -> servers secrets only
			if strings.Join(res.Retype, ",") != "remnawave_url,remnawave_token,servers/id_serp" {
				t.Fatalf("retype %v", res.Retype)
			}
			all, _ := Import(context.Background(), arch, ImportOptions{Roots: dst, FS: fx, Tag: "restore", Compressor: comp})
			if len(all.Retype) != 5 {
				t.Fatalf("nil modules => all: %v", all.Retype)
			}
		})
	}
}

func TestSettingsFilteredAndLocationKept(t *testing.T) {
	src, _ := mkHome(t)
	arch, err := Export(ExportOptions{Roots: src, Host: "h", Now: now, OutDir: t.TempDir(), Compressor: Identity{}})
	if err != nil {
		t.Fatal(err)
	}
	dst := Roots{Config: t.TempDir(), State: t.TempDir(), Notes: t.TempDir()}
	// the new system already has its own location
	w(t, dst.Config+"/serpantinum/settings.json", `{"general":{"location":"New Place"}}`)
	fx, _ := fsx.New(fsx.Config{Allowed: []string{dst.Config, dst.State, dst.Notes}, StateDir: t.TempDir(), Run: "r1"})
	if _, err := Import(context.Background(), arch, ImportOptions{Roots: dst, FS: fx, Tag: "t", Compressor: Identity{}}); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dst.Config + "/serpantinum/settings.json")
	var d map[string]any
	if err := json.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	g := d["general"].(map[string]any)
	if g["location"] != "New Place" || g["language"] != "ru" {
		t.Fatalf("%v", g)
	}
	if _, ok := d["ai"].(map[string]any)["apiKey"]; ok {
		t.Fatal("apiKey restored")
	}
	if d["hotkeys"] == nil || d["vpn"] == nil {
		t.Fatal("hotkeys/vpn lost")
	}
	// the previous settings.json was backed up by fsx
	backed := false
	for _, c := range fx.Changes() {
		if strings.HasSuffix(c.Path, "settings.json") && c.Backup != "" {
			backed = true
		}
	}
	if !backed {
		t.Fatalf("settings.json not backed up: %+v", fx.Changes())
	}
}

// craft builds a tar with arbitrary entries for hostile-input tests.
func craft(t *testing.T, entries func(tw *tar.Writer)) string {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	entries(tw)
	tw.Close()
	p := filepath.Join(t.TempDir(), "x.tar.zst")
	os.WriteFile(p, buf.Bytes(), 0o600)
	return p
}

func put(tw *tar.Writer, name, data string) {
	tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), Typeflag: tar.TypeReg})
	tw.Write([]byte(data))
}

func manJSON(files ...FileEntry) string {
	b, _ := json.Marshal(Manifest{Format: 1, Files: files})
	return string(b)
}

func sha(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func TestImportRejectsBadArchives(t *testing.T) {
	dst := Roots{Config: t.TempDir(), State: t.TempDir(), Notes: t.TempDir()}
	fx, _ := fsx.New(fsx.Config{Allowed: []string{dst.Config, dst.State, dst.Notes}, StateDir: t.TempDir(), Run: "r"})
	opt := ImportOptions{Roots: dst, FS: fx, Tag: "t", Compressor: Identity{}}
	good := FileEntry{Path: "data/notes/a.md", SHA256: sha("hi"), Size: 2, Mode: 0o644}
	cases := map[string]func(*tar.Writer){
		"sha mismatch": func(tw *tar.Writer) {
			e := good
			e.SHA256 = sha("other")
			put(tw, "manifest.json", manJSON(e))
			put(tw, good.Path, "hi")
		},
		"missing file":   func(tw *tar.Writer) { put(tw, "manifest.json", manJSON(good)) },
		"unlisted extra": func(tw *tar.Writer) { put(tw, "manifest.json", manJSON()); put(tw, "data/notes/evil", "x") },
		"traversal": func(tw *tar.Writer) {
			e := FileEntry{Path: "data/notes/../../etc/x", SHA256: sha("hi"), Size: 2}
			put(tw, "manifest.json", manJSON(e))
			put(tw, e.Path, "hi")
		},
		"outside data": func(tw *tar.Writer) {
			e := FileEntry{Path: "etc/passwd", SHA256: sha("hi"), Size: 2}
			put(tw, "manifest.json", manJSON(e))
			put(tw, e.Path, "hi")
		},
		"symlink": func(tw *tar.Writer) {
			tw.WriteHeader(&tar.Header{Name: "data/notes/l", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd"})
		},
		"no manifest": func(tw *tar.Writer) { put(tw, "data/notes/a.md", "hi") },
	}
	for name, fn := range cases {
		p := craft(t, fn)
		if _, err := Import(context.Background(), p, opt); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if ents, _ := os.ReadDir(dst.Notes); len(ents) != 0 {
		t.Fatal("something was written")
	}
	// a valid one passes
	p := craft(t, func(tw *tar.Writer) { put(tw, "manifest.json", manJSON(good)); put(tw, good.Path, "hi") })
	if _, err := Import(context.Background(), p, opt); err != nil {
		t.Fatal(err)
	}
}

func TestFilterSettings(t *testing.T) {
	out, st, err := FilterSettings([]byte(`{"general":{"location":"x","a":1},"vpn":{"subscription":"s","mode":"all","nested":{"my_token":"t"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, bad := range []string{"location", "subscription", "my_token"} {
		if strings.Contains(s, bad) {
			t.Errorf("%s kept", bad)
		}
	}
	if !strings.Contains(s, `"mode"`) || len(st) != 3 {
		t.Fatalf("%s %v", s, st)
	}
	if _, _, err := FilterSettings([]byte("not json")); err == nil {
		t.Fatal("want error")
	}
}

func TestAutoBackupSecretsCopy(t *testing.T) {
	src, home := mkHome(t)
	share := filepath.Join(home, ".local/share/serpantinum-installer")
	var last *AutoResult
	for i, run := range []string{"20261001-1000", "20261002-1000", "20261003-1000"} {
		r, err := AutoBackup(AutoOptions{ExportOptions: ExportOptions{Roots: src, Host: "h", Now: now.Add(time.Duration(i) * time.Hour),
			OutDir: filepath.Join(home, "serpantinum-backups"), Compressor: Identity{}}, Run: run, ShareDir: share})
		if err != nil {
			t.Fatal(err)
		}
		last = r
	}
	st, err := os.Stat(last.SecretsCopy)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", err, st)
	}
	for _, d := range []string{share, filepath.Dir(share) + "/serpantinum-installer/backups", filepath.Dir(last.SecretsCopy)} {
		if s, _ := os.Stat(d); s.Mode().Perm() != 0o700 {
			t.Errorf("%s: %v", d, s.Mode().Perm())
		}
	}
	ents, _ := os.ReadDir(filepath.Join(share, "backups"))
	if len(ents) != 2 {
		t.Fatalf("keep 2: %d", len(ents))
	}
	// the exported archive has no secrets, the local copy has them
	if b := decompressed(t, Identity{}, last.Archive); bytes.Contains(b, []byte(fakeGemini)) {
		t.Fatal("archive has secret")
	}
	cp, _ := os.ReadFile(last.SecretsCopy)
	for _, s := range []string{fakeGemini, fakeToken, fakeSub, fakePriv} {
		if !bytes.Contains(cp, []byte(s)) {
			t.Errorf("copy lacks %q", s)
		}
	}
	if bytes.Contains(cp, []byte(fakeHosts)) {
		t.Error("known_hosts in copy")
	}
	fi, _ := os.Stat(last.Archive)
	if fi.Mode().Perm() != 0o600 {
		t.Fatal("archive perm")
	}

	// restore into a "reinstalled" home with empty secrets/
	dst := Roots{Config: t.TempDir(), State: t.TempDir(), Notes: t.TempDir()}
	fx, _ := fsx.New(fsx.Config{Allowed: []string{dst.Config}, StateDir: t.TempDir(), Run: "r"})
	got, err := RestoreSecretsIfEmpty(context.Background(), dst, share, fx, "secrets")
	if err != nil || len(got) != 4 {
		t.Fatalf("%v %v", err, got)
	}
	b, _ := os.ReadFile(dst.Config + "/serpantinum/secrets/gemini_key")
	if string(b) != fakeGemini {
		t.Fatal("not restored")
	}
	if s, _ := os.Stat(dst.Config + "/serpantinum/secrets"); s.Mode().Perm() != 0o700 {
		t.Fatalf("secrets dir %v", s.Mode().Perm())
	}
	if s, _ := os.Stat(dst.Config + "/serpantinum/secrets/gemini_key"); s.Mode().Perm() != 0o600 {
		t.Fatal("secret file perm")
	}
	// not empty -> untouched
	if got, _ := RestoreSecretsIfEmpty(context.Background(), dst, share, fx, "secrets"); got != nil {
		t.Fatalf("second restore %v", got)
	}
	if err := RemoveSecretCopies(share); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(share, "backups")); err == nil {
		t.Fatal("not removed")
	}
}

func TestNoSecretsDir(t *testing.T) {
	r := Roots{Config: t.TempDir(), State: t.TempDir(), Notes: t.TempDir() + "/missing"}
	w(t, r.Config+"/serpantinum/settings.json", `{}`)
	res, err := AutoBackup(AutoOptions{ExportOptions: ExportOptions{Roots: r, Host: "h", Now: now, OutDir: t.TempDir(), Compressor: Identity{}}, Run: "r", ShareDir: t.TempDir()})
	if err != nil || res.SecretsCopy != "" {
		t.Fatalf("%v %+v", err, res)
	}
}

func TestFilterSettingsKeepsBytesWhenNothingStripped(t *testing.T) {
	in := []byte("{\"z\": 1,\n  \"a\": {\"b\": 2}}")
	out, st, err := FilterSettings(in)
	if err != nil || len(st) != 0 || string(out) != string(in) {
		t.Fatalf("out=%q st=%v err=%v", out, st, err)
	}
}
