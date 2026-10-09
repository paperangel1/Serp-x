package engine

import "serpx/installer/internal/run"

func cmdOf(name string, root bool, args ...string) run.Cmd {
	return run.Cmd{Name: name, Args: args, Root: root}
}
