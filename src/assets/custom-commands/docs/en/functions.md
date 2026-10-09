# Functions (custom nodes)

Select several nodes and press «Collapse into a node»: the editor finds inputs and outputs from the wires crossing the selection and creates a function. It appears in the palette like any node and in the «Function library».

- Inside a function there are «Function input» and «Function output» nodes: data enters and leaves through them.
- A function can be opened, changed and saved: the change affects every place that uses it.
- A function cannot call itself, even through others, and nesting is limited to eight levels.
- A function's capabilities are the union of its nodes' capabilities; they are shown in the node help.
- Functions can be exported and imported; an imported function gets no approved rights.
