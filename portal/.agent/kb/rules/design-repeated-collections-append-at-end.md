# Repeated collections append at the end

## Rule

Render the shared full-width dashed `<.add_row>` immediately after the final
item in a repeated configuration collection. It is the one Add affordance for
that collection. Do not move it into the section header or place a compact Add
button beside the collection label.

An empty collection may include one short explanation before the add row. The
action stays in the same place before and after items exist, and a newly added
row appears directly above the control that created it.

## Why

A header Add button separates cause from effect: the operator clicks at the top
and must search below for the inserted row. It becomes worse in long editors,
where the final item may be several screens away. Mixing compact header buttons
with dashed end rows also gives identical collection operations two visual
grammars.

## Good

- Input cards followed by `+ Add input`.
- Enum values followed by `+ Add value`.
- Stages, steps, outputs, conditions, and policy overrides using the same
  full-width dashed row after their last item.
- An empty-state sentence followed by the same add row used in the populated
  state.

## Bad

- `Add input` in the section header while input cards render below.
- `Add value` floated beside “Allowed values.”
- Both a header Add button and an end Add row for the same collection.
- A tiny icon-only plus whose target collection is not obvious.

## Enforced

Rendered tests assert each collection's Add control follows its last item and
that no duplicate header Add exists. Screenshot review covers empty and
populated collections on desktop and narrow layouts.

Sweep editor and settings components for right-aligned or header-level `Add …`
buttons whose event appends a repeated row.
