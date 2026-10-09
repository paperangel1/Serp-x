<!-- This file is generated from the node schema; do not edit it by hand. -->

## Logic

### Ask me (`logic.ask@1`)

Shows a question in the shell: pick from a list, enter text, enter a number or yes/no. "Cancelled" and "Timed out" outputs run when there is no answer. Without a connected shell, "Timed out" runs.

- Kind: latent (may wait)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `mode` | input | text | Question kind | choice |
| `title` | input | text | Question | Вопрос |
| `options` | input | list (text) | Options | [] |
| `default` | input | text | Default value |  |
| `timeout` | input | decimal number | Wait for answer (seconds) | 120 |
| `exec_out` | output | execution | Answered |  |
| `cancelled` | output | execution | Cancelled |  |
| `timed_out` | output | execution | Timed out |  |
| `text` | output | text | Answer (text) |  |
| `number` | output | decimal number | Answer (number) |  |
| `index` | output | number | Option number | -1 |
| `yes` | output | yes/no | Answer yes |  |

**Example:** Ask "What to turn on?" with options → act on the answer.

### Break loop (`logic.break@1`)

Stops the nearest "For each" loop and continues from its "Completed" output. Only valid inside a loop body.

- Kind: action (follows the execution wire)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |

**Example:** If the file is found → break the loop.

### Delay (`logic.delay@1`)

Waits the given number of seconds, then continues. The command can be cancelled while waiting.

- Kind: latent (may wait)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `seconds` | input | decimal number | Seconds | 1 |
| `exec_out` | output | execution | Done |  |

**Example:** Notification → delay 5 s → second notification.

### For each (`logic.foreach@1`)

Runs the "Body" branch for every list item; when the list ends, "Completed" runs.

- Kind: action (follows the execution wire)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `list` | input | list (T) | List |  |
| `body` | output | execution | Body |  |
| `item` | output | T | Item |  |
| `index` | output | number | Index | 0 |
| `completed` | output | execution | Completed |  |

**Example:** For each file in the list → notification with its name.

### If (`logic.if@1`)

Chooses a branch: when the condition is yes, "Then" runs, otherwise "Else".

- Kind: action (follows the execution wire)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `condition` | input | yes/no | Condition |  |
| `then` | output | execution | Then |  |
| `else` | output | execution | Else |  |

**Example:** If volume is above 50 → notification "Loud".

### Increment variable (`logic.increment@1`)

Adds a number to a numeric command variable (1 by default) and returns the new value.

- Kind: action (follows the execution wire)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `name` | input | text | Variable name |  |
| `by` | input | decimal number | Add | 1 |
| `exec_out` | output | execution | Done |  |
| `value` | output | any value | New value |  |

**Example:** Counter "tries" + 1.

### Set variable (`logic.set_var@1`)

Stores a value in a command variable. The value's type must match the variable's type.

- Kind: action (follows the execution wire)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `name` | input | text | Variable name |  |
| `value` | input | any value | Value |  |
| `exec_out` | output | execution | Done |  |

**Example:** Set variable "greeting" = "Hello".

### Wait for event (`logic.wait_event@1`)

Pauses the command until a matching event arrives (window, workspace, monitor, session lock). If nothing arrives in time, the "Timed out" output runs. The command can be cancelled while waiting.

- Kind: latent (may wait)
- Capabilities: `trigger.windows`, `trigger.session`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `event` | input | text | Event | window.open |
| `match` | input | text | Filter |  |
| `timeout` | input | decimal number | Wait (seconds) | 60 |
| `exec_out` | output | execution | Event arrived |  |
| `timed_out` | output | execution | Timed out |  |
| `detail` | output | text | Event data |  |

**Example:** Wait up to 60 seconds for a browser window → notification.

