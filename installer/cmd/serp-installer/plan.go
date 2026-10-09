package main

// Dry-run: prints the plan built by internal/plan (installer/04 section 4.2).

import (
	"errors"
	"fmt"
	"io"
	"math"
	"strings"

	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plan"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/xlog"
)

func dryRunInstall(o *options, set *manifest.Set, cat *i18n.Catalog, lang string, stdout, stderr io.Writer, getenv func(string) string, log *xlog.Logger) int {
	t := func(key string, kv ...string) string { return cat.T(lang, key, kv...) }
	r := resolve.New(set)

	var explicit []string
	switch o.preset {
	case resolve.PresetCustom:
		explicit = resolve.ParseList(o.modules)
	case resolve.PresetFull, resolve.PresetMinimal:
		var err error
		explicit, err = r.Preset(o.preset, detectFromFlags(o))
		if err != nil {
			fmt.Fprintln(stderr, err)
			return exitUsage
		}
		if o.modules != "" { // extra modules on top of a preset
			explicit = append(explicit, resolve.ParseList(o.modules)...)
		}
	default:
		fmt.Fprintln(stderr, t("err.unknown_preset", "name", o.preset))
		return exitUsage
	}
	sel, err := r.Resolve(explicit)
	if err != nil {
		var ue *resolve.UnknownError
		var ce *resolve.ConflictError
		switch {
		case errors.As(err, &ue):
			fmt.Fprintln(stderr, t("err.unknown_module", "id", ue.ID))
		case errors.As(err, &ce):
			fmt.Fprintln(stderr, t("err.conflict", "a", ce.A, "b", ce.B))
		default:
			fmt.Fprintln(stderr, err)
		}
		return exitUsage
	}

	list, err := plan.Build(plan.Input{
		Set: set, Sel: sel, Cat: cat, Restore: o.restore != "",
		Opts: steps.Options{Compositors: []string{"hyprland"}, InstallState: steps.DetectInstallState(getenv("HOME"))},
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitFailure
	}
	fmt.Fprintln(stdout, t("plan.header", "steps", itoa(len(list)), "modules", itoa(len(sel.Modules)), "list", strings.Join(sel.Modules, ", ")))
	for i, s := range list {
		line := t("plan.step", "i", pad(i+1, len(list)), "n", itoa(len(list)), "title", s.Title(lang))
		if s.Root() {
			line += "  (" + t("plan.sudo_mark") + ")"
		}
		fmt.Fprintln(stdout, line)
	}
	for _, id := range sortedKeys(sel.Auto) {
		fmt.Fprintln(stdout, "  "+id+": "+t("plan.auto_mark", "by", strings.Join(sel.Auto[id], ", ")))
	}
	for _, w := range sel.Warnings {
		if w.Kind == resolve.Enhances {
			fmt.Fprintln(stdout, "  "+t("plan.enhances", "id", w.Module, "list", strings.Join(w.Affected, ", ")))
		}
	}
	var mib float64
	var secs int
	for _, id := range sel.Modules {
		m, _ := set.Get(id)
		mib += m.Estimate.DownloadMiB
		secs += m.Estimate.InstallS + m.Estimate.BuildS
	}
	fmt.Fprintln(stdout, t("plan.totals", "mib", itoa(int(math.Round(mib))), "min", itoa(max(1, (secs+30)/60))))
	fmt.Fprintln(stdout, t("plan.dry_run_done"))
	log.Info("dry-run plan", "preset", o.preset, "modules", strings.Join(sel.Modules, ","), "steps", len(list))
	return exitOK
}

func itoa(n int) string { return fmt.Sprintf("%d", n) }

func pad(i, n int) string {
	w := len(itoa(n))
	return fmt.Sprintf("%*d", w, i)
}
