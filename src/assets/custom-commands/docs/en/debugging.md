# Debugging and rehearsal

- **Checks.** The editor validates the graph all the time: errors (red) block running, warnings (yellow) do not. Each message says what is wrong and how to fix it.
- **Trace.** After a run open the «Trace»: step by step you see which node ran, which values went in and out, and how long it took. `serpantinum-x cmd trace <name>` shows the same in a terminal.
- **Values on hover.** Hover a pin to see its value from the last run.
- **Stepping and breakpoints.** Stop on a node, look at the values, step on or continue.
- **Rehearsal.** A run «for pretend»: actions are only described and change nothing, time is sped up, questions can be answered in advance (`--answer`), events for «Wait for event» are simulated (`--sim-event`). It is a safe way to test new commands: `serpantinum-x run "Name" --rehearse --steps`.
- Run log: `serpantinum-x cmd log`.
