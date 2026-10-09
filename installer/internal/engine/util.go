package engine

import (
	"encoding/json"
	"os"
	"serpx/installer/internal/manifest"
)

func readFile(p string) ([]byte, error)   { return os.ReadFile(p) }
func jsonUnmarshal(b []byte, v any) error { return json.Unmarshal(b, v) }

type manifestText = manifest.Text
