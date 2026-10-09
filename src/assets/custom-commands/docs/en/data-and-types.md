# Data and types

Coloured circles are data. Data flows along coloured wires from the output of one node to the input of another.

A wire joins only pins of the same type. Types: `exec` (order), yes/no, number (`int`), decimal number (`float`), text, time, duration, colour, path, link, device, data (`json`), any value (`any`) and lists `list<type>`.

- Only two conversions are implicit: number → decimal and any type → «any value».
- Everything else needs an explicit converter node («To text», «To number»). When types do not match, the editor offers to insert one in a click.
- «Pure» data nodes (math, text, comparison) have no execution order: they are computed when a value is needed.
- An unconnected input takes the value typed in the node (a literal). A required empty input is an error.
- In logs: secret values are hidden, long texts and the clipboard are written as a length only.
