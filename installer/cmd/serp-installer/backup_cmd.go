package main

import (
	"context"
	"fmt"
	"os"
	"strconv"

	"serpx/installer/internal/app"
)

// cmdBackup: `backup export [--out DIR]` and `backup import FILE`.
func cmdBackup(c *runCtx) int {
	if len(c.rest) == 0 {
		fmt.Fprintln(c.stderr, c.t("err.backup_usage"))
		return exitUsage
	}
	svc, err := c.service("backup")
	if err != nil {
		fmt.Fprintln(c.stderr, c.t("err.backup_failed", "error", err.Error()))
		return exitFailure
	}
	switch c.rest[0] {
	case "export":
		p, err := svc.ExportBackup(c.o.out)
		if err != nil {
			fmt.Fprintln(c.stderr, c.t("err.backup_failed", "error", err.Error()))
			return exitFailure
		}
		fmt.Fprintln(c.stdout, c.t("msg.backup_written", "path", p))
	case "import":
		file := c.o.restore
		if len(c.rest) > 1 {
			file = c.rest[1]
		}
		if file == "" {
			fmt.Fprintln(c.stderr, c.t("err.backup_usage"))
			return exitUsage
		}
		res, err := svc.ImportBackup(context.Background(), file)
		if err != nil {
			fmt.Fprintln(c.stderr, c.t("err.backup_failed", "error", err.Error()))
			return exitFailure
		}
		fmt.Fprintln(c.stdout, c.t("msg.backup_restored", "n", strconv.Itoa(len(res.Restored))))
		if len(res.Retype) > 0 {
			fmt.Fprintln(c.stdout, c.t("msg.backup_retype"))
			for _, n := range res.Retype {
				fmt.Fprintln(c.stdout, "  - "+n)
			}
		}
		for _, w := range res.Warnings {
			fmt.Fprintln(c.stderr, w)
		}
	default:
		fmt.Fprintln(c.stderr, c.t("err.backup_usage"))
		return exitUsage
	}
	return exitOK
}

// cmdExportConfig writes my-setup.toml for the current system (no secrets).
func cmdExportConfig(c *runCtx) int {
	svc, err := c.service("export-config")
	if err != nil {
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	data, err := svc.ExportConfig(c.lang)
	if err != nil {
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	if c.o.out == "" {
		c.stdout.Write(data)
		return exitOK
	}
	if err := os.WriteFile(c.o.out, data, 0o600); err != nil {
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	fmt.Fprintln(c.stdout, c.t("msg.config_saved", "path", c.o.out))
	return exitOK
}

var _ = app.ModeReconcile
