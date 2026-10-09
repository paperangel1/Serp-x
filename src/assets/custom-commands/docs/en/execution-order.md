# Execution order

Order is set by the **white wire** between the «Run» and «Done» diamonds. A node starts when the white wire reaches it and hands control on only when it has finished.

- One chain leaves an event: A → B → C. Two wires from one execution output are not allowed: use «If» or «For each».
- A node without a white wire never runs. The editor warns «unreachable».
- Waiting nodes («Delay», «Ask me», «Wait for event») pause the chain until an answer arrives or time runs out. A run can be cancelled.
- A node error stops the run unless the node is set to «continue on error».
- Order cannot loop back on itself: use «For each» for repetition.
