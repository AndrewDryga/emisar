# Forms reveal before they validate

## Rule

**A `phx-change` render never reports a required-value error for a field the
operator has not filled.** A change event carries every field in the form, so
marking the changeset validated on change accuses them of every blank they have
not reached yet — picking a provider from a dropdown put "can't be blank" under
Issuer URL before the cursor had been in it. Errors appear when the operator
fills a field or submits, never merely because they touched something else.
In this codebase that is `EmisarWeb.LiveForm.on_change/1`; suppressing the error
must never mean skipping the validation, so submit paths use the changeset as-is.

The same timing governs conditional branches. When selecting one option reveals
required dependent controls, reveal the controls without showing their
missing-value error. The revealed controls visually continue the selected option:
one surface, one outline, no repeated heading, and a smaller child type tier.
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
- `Map.put(changeset, :action, :validate)` in a change handler, which reports
  every blank field in the form rather than the one being edited.
- The chosen card is followed by an error, a duplicate heading, and a second box.
- The trigger has a focus outline that stops before its attached panel.
- Nested option labels are larger than the choice that owns them.
- Hiding the error also removes server-side validation on submit.

## Enforced

LiveView tests cover the timing contract: a change targeting ANOTHER field raises
no error, a change targeting the field itself does, and an invalid submit does.

A test asserting "error appears on change" must pass `_target` —
`render_change(%{"_target" => ["invite", "email"]})`. `render_change/1` omits it
while a browser always sends it, so a test without it is asserting a payload that
cannot occur, and will fail against correct code. Shared component tests pin the
attached selected-card shape and the compact, 40px runner rows. Screenshot review
covers desktop and mobile because the attachment, compound focus outline, and
hierarchy are visual contracts.

## Sweep target

Search change handlers for `Map.put(:action, :validate)` — every one of them
reports blanks the operator has not reached. `EmisarWeb.LiveForm.on_change/1`
replaces it. Submit paths keep the raw changeset, so check the enclosing function
before swapping: `profile_live`'s `save_email` sets the action inside a SUBMIT
path and must keep the full error set.
Search for `phx-change` forms that conditionally reveal a required child and render
its error from `field.errors` alone. Search for `choice_cards` immediately followed
by a separately labeled or framed dependent control.
Search attached panels whose side or bottom border does not follow the trigger's
focus state, or whose internal divider incorrectly receives the focus color.
