package app

import (
	"encoding/json"
	"fmt"
	"strings"
)

// jsonString reads a dotted path from a JSON document; anything that is not
// there (or not a scalar) gives "".
func jsonString(b []byte, path string) string {
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		return ""
	}
	var cur any = m
	for _, p := range strings.Split(path, ".") {
		mm, ok := cur.(map[string]any)
		if !ok {
			return ""
		}
		cur = mm[p]
	}
	switch v := cur.(type) {
	case string:
		return v
	case bool:
		return boolText(v)
	case float64:
		return fmt.Sprint(v)
	}
	return ""
}
