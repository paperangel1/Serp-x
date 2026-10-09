// Package resolve turns a user's module choice into a consistent, ordered
// selection: requires are pulled in, conflicts are rejected, removals are
// checked for cascades.
package resolve

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"serpx/installer/internal/manifest"
)

// Detect carries detected system facts that influence presets.
type Detect struct {
	// Tags such as "gpu:nvidia". Matched against manifest recommend_if.
	Tags []string
}

func (d Detect) has(tag string) bool {
	for _, t := range d.Tags {
		if t == tag {
			return true
		}
	}
	return false
}

// WarningKind classifies a Warning.
type WarningKind string

const (
	// CascadeOff: deselecting a module would also disable modules that need it.
	CascadeOff WarningKind = "cascade-off"
	// Enhances: a soft hint (module X works better with Y).
	Enhances WarningKind = "enhances"
)

// Warning is a non-fatal remark the UI shows to the user.
type Warning struct {
	Kind     WarningKind
	Module   string   // the module the warning is about
	Affected []string // CascadeOff: modules that need Module; Enhances: the suggested modules
}

// Selection is the resolved result.
type Selection struct {
	// Modules in dependency order (requires first, stable by manifest order).
	Modules []string
	// Auto maps each module that was added only because others need it
	// (not chosen explicitly, and not core) to the selected modules that
	// require it directly ("needed for: ...").
	Auto     map[string][]string
	Warnings []Warning
}

// Has reports whether id is selected.
func (s *Selection) Has(id string) bool {
	for _, m := range s.Modules {
		if m == id {
			return true
		}
	}
	return false
}

// Errors.
var (
	ErrCoreRequired = errors.New("core cannot be deselected")
)

// UnknownError is returned for ids that have no manifest.
type UnknownError struct{ ID string }

func (e *UnknownError) Error() string { return fmt.Sprintf("unknown module %q", e.ID) }

// ConflictError is returned when two selected modules conflict.
type ConflictError struct{ A, B string }

func (e *ConflictError) Error() string {
	return fmt.Sprintf("modules %q and %q cannot be installed together", e.A, e.B)
}

// Resolver works on a validated manifest set.
type Resolver struct {
	set   *manifest.Set
	index map[string]int
}

// New creates a resolver.
func New(set *manifest.Set) *Resolver {
	r := &Resolver{set: set, index: map[string]int{}}
	for i, m := range set.List {
		r.index[m.ID] = i
	}
	return r
}

// Resolve computes the full selection for the explicitly chosen modules.
// core is always included.
func (r *Resolver) Resolve(explicit []string) (*Selection, error) {
	chosen := map[string]bool{}
	for _, id := range explicit {
		if _, ok := r.set.Get(id); !ok {
			return nil, &UnknownError{id}
		}
		chosen[id] = true
	}
	core := r.set.Core().ID
	in := map[string]bool{core: true}
	var add func(id string)
	add = func(id string) {
		if in[id] {
			return
		}
		in[id] = true
		m, _ := r.set.Get(id)
		for _, req := range m.Requires {
			add(req)
		}
	}
	for id := range chosen {
		add(id)
	}

	order := r.topo(in)

	// conflicts (symmetric)
	for _, id := range order {
		m, _ := r.set.Get(id)
		for _, c := range m.Conflicts {
			if in[c] {
				a, b := id, c
				if r.index[b] < r.index[a] {
					a, b = b, a
				}
				return nil, &ConflictError{a, b}
			}
		}
	}

	sel := &Selection{Modules: order, Auto: map[string][]string{}}
	for _, id := range order {
		if chosen[id] || id == core {
			continue
		}
		var by []string
		for _, other := range order {
			om, _ := r.set.Get(other)
			if contains(om.Requires, id) {
				by = append(by, other)
			}
		}
		sel.Auto[id] = by
	}
	// soft hints
	for _, id := range order {
		m, _ := r.set.Get(id)
		var missing []string
		for _, e := range m.Enhances {
			if !in[e] {
				missing = append(missing, e)
			}
		}
		if len(missing) > 0 {
			sel.Warnings = append(sel.Warnings, Warning{Kind: Enhances, Module: id, Affected: missing})
		}
	}
	return sel, nil
}

// topo orders a set of ids: Kahn over `requires`, stable by manifest order.
// The set must be closed under requires and acyclic (guaranteed by manifest
// validation).
func (r *Resolver) topo(in map[string]bool) []string {
	var ids []string
	for id := range in {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return r.index[ids[i]] < r.index[ids[j]] })
	done := map[string]bool{}
	var out []string
	for len(out) < len(ids) {
		progressed := false
		for _, id := range ids {
			if done[id] {
				continue
			}
			m, _ := r.set.Get(id)
			ready := true
			for _, req := range m.Requires {
				if !done[req] {
					ready = false
					break
				}
			}
			if ready {
				done[id] = true
				out = append(out, id)
				progressed = true
				break // restart the scan: keeps manifest order stable
			}
		}
		if !progressed { // unreachable for validated sets
			panic("resolve: requires cycle in validated set")
		}
	}
	return out
}

// Dependents returns the modules in sel that (transitively) require id,
// in dependency order.
func (r *Resolver) Dependents(sel *Selection, id string) []string {
	dep := map[string]bool{id: true}
	var out []string
	for _, m := range sel.Modules { // requires-first order: one pass is enough
		if m == id {
			continue
		}
		mm, _ := r.set.Get(m)
		for _, req := range mm.Requires {
			if dep[req] {
				dep[m] = true
				out = append(out, m)
				break
			}
		}
	}
	return out
}

// Deselect removes id from the explicit choice.
//
// If other selected modules need id and cascade is false, nothing changes and
// a CascadeOff warning is returned (the UI shows "[Remove both] [Cancel]").
// With cascade true, id and everything that needs it is removed. core cannot
// be removed (ErrCoreRequired).
func (r *Resolver) Deselect(explicit []string, id string, cascade bool) ([]string, *Warning, error) {
	m, ok := r.set.Get(id)
	if !ok {
		return nil, nil, &UnknownError{id}
	}
	if m.Core {
		return nil, nil, ErrCoreRequired
	}
	sel, err := r.Resolve(explicit)
	if err != nil {
		return nil, nil, err
	}
	affected := r.Dependents(sel, id)
	if len(affected) > 0 && !cascade {
		return append([]string(nil), explicit...), &Warning{Kind: CascadeOff, Module: id, Affected: affected}, nil
	}
	drop := map[string]bool{id: true}
	for _, a := range affected {
		drop[a] = true
	}
	var out []string
	for _, e := range explicit {
		if !drop[e] {
			out = append(out, e)
		}
	}
	return out, nil, nil
}

// Preset names.
const (
	PresetFull    = "full"
	PresetMinimal = "minimal"
	PresetCustom  = "custom"
)

// Preset returns the explicit module list of a preset, in manifest order.
// "full" = manifests tagged presets=["full"] plus modules whose recommend_if
// tag was detected; "minimal" likewise; "custom" returns nil (user decides).
func (r *Resolver) Preset(name string, det Detect) ([]string, error) {
	switch name {
	case PresetCustom:
		return nil, nil
	case PresetFull, PresetMinimal:
	default:
		return nil, fmt.Errorf("unknown preset %q (want full, minimal or custom)", name)
	}
	var out []string
	for _, m := range r.set.List {
		if contains(m.Presets, name) {
			out = append(out, m.ID)
			continue
		}
		if name == PresetFull && m.RecommendIf != "" && det.has(m.RecommendIf) {
			out = append(out, m.ID)
		}
	}
	return out, nil
}

// ParseList splits "a,b c" into ids (comma or space separated).
func ParseList(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ' ' })
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
