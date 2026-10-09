<!-- This file is generated from the node schema; do not edit it by hand. -->

## Interface

### Show result (`ui.show_result@1`)

Shows a value in a shell window. If the shell does not answer within 3 seconds, the value is shown as a plain notification.

- Kind: latent (may wait)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `exec_in` | input | execution |  |  |
| `title` | input | text | Title |  |
| `value` | input | any value | Value |  |
| `exec_out` | output | execution | Done |  |

**Example:** Output of `date` → show result.

