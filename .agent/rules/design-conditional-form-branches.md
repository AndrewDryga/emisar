# Conditional form branches reveal before they validate

## Rule

When selecting one option reveals required dependent controls, reveal the controls
without showing their missing-value error. Show that error only after the operator
submits the form. The revealed controls visually continue the selected option: one
surface, one outline, no repeated heading, and a smaller child type tier.
When the trigger receives focus, that outline encloses the attached panel's
sides and bottom; the internal divider stays neutral.

## Why

A selection is not a failed submission. Immediate errors punish the operator for
entering a branch before they have had a chance to complete it. A detached picker
also makes the dependency ambiguous: it can read as a separate field instead of the
content required by the selected option.

## Good

- Clicking `Selected runners` opens the runner tree directly under that choice.
- The choice and tree share one selected surface and outline.
- Focus outlines wrap the whole compound control without coloring its divider.
- The empty-tree error appears after `Save`, `Add`, or `Send invite` is attempted.
- Group labels use the normal form text tier; child runner labels step down once.
- Every selectable row retains at least a 40px hit target.

## Bad

- `phx-change` adds an error as soon as the conditional option is clicked.
- The chosen card is followed by an error, a duplicate heading, and a second box.
- The trigger has a focus outline that stops before its attached panel.
- Nested option labels are larger than the choice that owns them.
- Hiding the error also removes server-side validation on submit.

## Enforced

LiveView tests cover both halves of the timing contract: a mode-change render has no
dependency error, while an invalid submit does. Shared component tests pin the
attached selected-card shape and the compact, 40px runner rows. Screenshot review
covers desktop and mobile because the attachment, compound focus outline, and
hierarchy are visual contracts.

## Sweep target

Search for `phx-change` forms that conditionally reveal a required child and render
its error from `field.errors` alone. Search for `choice_cards` immediately followed
by a separately labeled or framed dependent control.
Search attached panels whose side or bottom border does not follow the trigger's
focus state, or whose internal divider incorrectly receives the focus color.
