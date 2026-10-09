package app

import (
	"archive/tar"
	"bytes"
)

func tarWriter(b *bytes.Buffer) func(name, data string) {
	tw := tar.NewWriter(b)
	return func(name, data string) {
		tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), Typeflag: tar.TypeReg})
		tw.Write([]byte(data))
		tw.Flush()
	}
}
