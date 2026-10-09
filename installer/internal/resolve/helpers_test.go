package resolve_test

import "testing/fstest"

func mapFS(files map[string]string) fstest.MapFS {
	fs := fstest.MapFS{}
	for n, c := range files {
		fs["m/"+n] = &fstest.MapFile{Data: []byte(c)}
	}
	return fs
}
