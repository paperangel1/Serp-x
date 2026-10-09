# Variables

A variable keeps a value between steps of one run. Declare it in the «Variables» panel (name and type), then use the nodes:

- «Set variable» stores a value;
- «Get variable» is a pure node that returns it (its type comes from the declaration);
- «Increment» adds a number (counters).

Variables live for one run and are not kept between runs. A variable's type is checked as strictly as pins: text cannot go into a numeric variable without conversion. A name missing from the declarations is flagged as an error.
