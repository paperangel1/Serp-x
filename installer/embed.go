// Package installer only carries the embedded data files (manifests and
// installer UI strings) so that the binary is self-contained.
package installer

import "embed"

// Manifests holds manifests/*.toml.
//
//go:embed manifests/*.toml
var Manifests embed.FS

// I18N holds i18n/{ru,en}.toml.
//
//go:embed i18n/*.toml
var I18N embed.FS
