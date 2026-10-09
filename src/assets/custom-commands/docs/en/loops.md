# Loops

«For each» takes a list and runs its «Body» branch for every item. The «Item» and «Index» outputs are the data of the current step. When the list ends the «Completed» branch runs.

- «Break loop» stops the loop early; outside a loop it is an error.
- A list can come from an event, from the `range` node, or from splitting text with «Split».
- A loop over a big list with no pauses gets a warning: add a «Delay» or limit the list.
- Repeating on a schedule is easier with the «Interval» event than with an endless loop.
