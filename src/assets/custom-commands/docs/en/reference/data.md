<!-- This file is generated from the node schema; do not edit it by hand. -->

## Data

### Text → Number (`convert.to_int@1`)

Parses text as a whole number. If it is not a number the node fails.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `text` | input | text | Text |  |
| `value` | output | number | Number |  |

**Example:** Command output "42" → number 42.

### Any → Text (`convert.to_text@1`)

Turns any value into text: a number into its digits, yes/no into "да"/"нет", a list into comma-separated items.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `value` | input | any value | Value |  |
| `text` | output | text | Text |  |

**Example:** Item index → to text → notification body.

### And (`data.and@1`)

Yes only when both inputs are yes.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | yes/no | A | False |
| `b` | input | yes/no | B | False |
| `result` | output | yes/no | Result |  |

**Example:** Loud AND night → yes.

### Compare numbers (`data.compare_number@1`)

Compares two numbers and returns yes or no.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | decimal number | Number A | 0 |
| `op` | input | text | Comparison | == |
| `b` | input | decimal number | Number B | 0 |
| `result` | output | yes/no | Result |  |

**Example:** Volume > 50 → yes.

### Compare texts (`data.compare_text@1`)

Compares two texts (equals, contains, starts with, ends with, regex) and returns yes or no.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | text | Text A |  |
| `op` | input | text | Comparison | equals |
| `b` | input | text | Text B |  |
| `ignore_case` | input | yes/no | Ignore case | True |
| `result` | output | yes/no | Result |  |

**Example:** Answer contains "yes" → yes.

### Concatenate (`data.concat@1`)

Joins two texts into one.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | text | Text A |  |
| `b` | input | text | Text B |  |
| `text` | output | text | Text |  |

**Example:** "Hello, " + name → "Hello, Ann".

### File kind (`data.file_kind@1`)

Classifies a file by extension and MIME type: image, document, archive, video, audio or other. The file itself is not read.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `path` | input | text | File |  |
| `kind` | output | text | Kind | other |
| `ext` | output | text | Extension |  |
| `mime` | output | text | MIME type |  |

**Example:** Path "report.pdf" → document.

### Format text (`data.format@1`)

Replaces {a}, {b}, {c} in the template with the input values (numbers and yes/no become text automatically).

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `template` | input | text | Template | {a} |
| `a` | input | any value | Value a |  |
| `b` | input | any value | Value b |  |
| `c` | input | any value | Value c |  |
| `text` | output | text | Text |  |

**Example:** "{a} of {b} left" → "3 of 10 left".

### Get variable (`data.get_var@1`)

Returns the current value of a command variable. The output type equals the variable's type.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `name` | input | text | Variable name |  |
| `value` | output | any value | Value |  |

**Example:** Get "greeting" → notification title.

### Join list (`data.join@1`)

Joins list items into one text using a separator.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `list` | input | list (any value) | List |  |
| `sep` | input | text | Separator | ,  |
| `text` | output | text | Text |  |

**Example:** A file list → "a.txt, b.txt".

### List item (`data.list_get@1`)

Takes a list item by its index (from zero). If the index is outside the list, the command stops with a clear error.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `list` | input | list (T) | List |  |
| `index` | input | number | Index | 0 |
| `item` | output | T | Item |  |

**Example:** Second item of the list → index 1.

### List length (`data.list_length@1`)

Counts the list items.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `list` | input | list (any value) | List |  |
| `length` | output | number | Length |  |

**Example:** A list of 3 files → 3.

### Math (`data.math@1`)

Computes add, subtract, multiply, divide, remainder, min, max. Returns both a decimal and a whole (rounded down) result.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | decimal number | Number A | 0 |
| `op` | input | text | Operation | + |
| `b` | input | decimal number | Number B | 0 |
| `result` | output | decimal number | Result |  |
| `whole` | output | number | Whole |  |

**Example:** 3 + 4 → 7.

### Not (`data.not@1`)

Turns yes into no and vice versa.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `value` | input | yes/no | Value | False |
| `result` | output | yes/no | Result |  |

**Example:** NOT quiet → loud.

### Or (`data.or@1`)

Yes when at least one input is yes.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `a` | input | yes/no | A | False |
| `b` | input | yes/no | B | False |
| `result` | output | yes/no | Result |  |

**Example:** Browser OR mail open → yes.

### Number range (`data.range@1`)

Creates a list of integers: start, start+1, … (count of them). Handy for "repeat N times".

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `start` | input | number | Start | 0 |
| `count` | input | number | Count | 3 |
| `list` | output | list (number) | List |  |

**Example:** 3 numbers from 1 → 1, 2, 3.

### Selected files (`data.selected_files@1`)

A list of files: from the run argument (one path per line, or file:// URIs); without it, from the clipboard: files copied in the file manager (Ctrl+C). Paths that do not exist are dropped.

- Kind: data (computed on demand)
- Capabilities: `read.selection`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `arg` | input | text | Run argument |  |
| `files` | output | list (text) | Files | [] |
| `count` | output | number | Count | 0 |

**Example:** Three pictures copied → a list of three paths.

### Selected text (`data.selected_text@1`)

The text selected with the mouse in any app (the Wayland primary selection). With nothing selected the clipboard content is used. The "source" output tells which: primary, clipboard or none.

- Kind: data (computed on demand)
- Capabilities: `read.selection`
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `text` | output | text | Text |  |
| `source` | output | text | Source | none |

**Example:** Select a word → it becomes the input of a translation.

### Split text (`data.split@1`)

Splits a text by a separator into a list of texts.

- Kind: data (computed on demand)
- Capabilities: none
- Changes state: no
- Undo: none
- Danger: none

| Pin | Direction | Type | Label | Default |
|---|---|---|---|---|
| `text` | input | text | Text |  |
| `sep` | input | text | Separator | , |
| `list` | output | list (text) | List |  |

**Example:** "apple,pear" by "," → a list of two.

