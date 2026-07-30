# Complex editors follow decision order

## Rule

Order a complex editor by the decisions an operator makes:

1. supply shared context and run-time inputs;
2. build the workflow in execution order;
3. review identity, validation, and canonical output;
4. save or publish.

Inside a workflow unit, choose the scope before behavior when scope determines
what behavior is available. Select targets first, then offer only actions
supported by every selected target. Resolve implementation facts such as the
current pack version rather than asking the operator to pin them. Execution mode
comes before its concurrency bound; a bound appears only for a mode where it
changes execution. Put a workflow unit's identifier beside its title when that
identity belongs to the unit's overview. Keep lower-level binding identifiers
and infrequently changed limits in a nearby disclosure after the behavior they
refine.

Inside a repeated form card, visual weight and row order follow the decisions an
operator makes. Pair identity with purpose, put behavior choices next, then show
conditional values, defaults, and bounds. Field labels carry the hierarchy when
that order is already clear; do not add a group heading merely to restate it.
Let flexible text fields grow only to a readable measure, keep finite choices at
a content-sized width, and cap the collection on wide canvases. Intentional
negative space is better than stretching controls to fill a uniform grid. Give
related rows one measure and right edge. The collection or card owns that
measure; do not add a second inner width cap that leaves a dead rail inside the
card. Inside a row, equal binary choices use the same compact width while the
domain-bearing choice takes the remaining space. Font treatment must not change
peer control heights.

A typed value uses a type-aware editor. Booleans offer no default, true, or
false; integer and number defaults use numeric controls with whole-number and
decimal steps respectively; strings use text. An enum's optional single default
is selected directly from its allowed values, so it cannot drift outside the
set or be mistyped in a second field. Repeated-row actions align with the input
surface rather than the field wrapper's label gap. Peer row actions share one
enclosure treatment and optical height; a labeled toggle beside a bare icon
button is not one control family. A selected default or option is ordinary
authoring state, not proof that an operation passed: keep its surface, text,
ring, and radio/check in the neutral zinc palette. Use structure and contrast
to make selection unmistakable; reserve semantic color for a real verdict or
consequence. LiveView click metadata uses domain-specific
`phx-value-*` names such as `enum`, never `phx-value-value`: the client
replaces that generic key with the native element's `.value`. Routine defaults
and constraints remain visible; disclosure is for genuinely secondary detail,
not a way to reclaim vertical space.

Do not show a control in a mode where it has no effect. If a value still changes
execution, keep it visible beside the choice it qualifies and explain the
interaction. On narrow screens, lifecycle actions may lead, but the primary
editing workflow renders before details, validation, canonical output, or other
secondary rails. Keep lifecycle rails limited to state transitions such as Save
and Publish. Do not add a Cancel or Back action there when it only duplicates
the page header or application navigation.

## Why

Schema order is optimized for storage, not authoring. Leading with identifiers
and compatibility syntax forces an operator to solve implementation details
before they have chosen what the workflow should do. Hiding a live execution
control creates a worse failure: the saved behavior changes without a visible
way to understand or edit it.

Progressive disclosure is appropriate for stable detail and disabled-by-default
advanced behavior, not for active behavior whose value still affects execution.
The goal is the complete applicable model with fewer simultaneous decisions,
never a reduced model.

## Good

- Context, inputs, ordered stages, then the details and publish review rail.
- A stage overview puts its compact identifier, expanding title, execution mode,
  and applicable concurrency bound on one wide row; narrow screens preserve the
  same order while stacking.
- Targets first; then an action compatible with all selected runners. The pack
  follows the action automatically and the step ID lives in a disclosure.
- Parallel stages show a concurrency cap; sequential stages do not.
- A secondary review rail becomes sticky only when it sits beside a visibly
  wider task column; otherwise it follows the workflow.
- Save and Publish stay together; the existing page navigation remains the one
  way to leave the editor.
- A run-time input pairs ID with description; then type, required, and sensitive;
  then enum values when applicable; otherwise its default and applicable lower
  and upper bounds share one row.
- Required and Sensitive use equal compact tracks while Type takes the remaining
  row width; every input row ends at the same edge.
- The input collection is capped on the page, while every row inside each input
  card fills the card's content width.
- Integer reads as whole numbers and Number as decimals allowed. Their default
  and bound controls enforce the corresponding numeric step.
- Every enum value carries one aligned Default toggle; selecting one clears the
  others, selecting it again clears the default, and removing it removes the
  default with it.
- The selected Default uses a neutral highlighted surface and filled zinc radio,
  not the green pass/allowed treatment.
- Default and delete use matching bordered enclosures and 40px hit areas; their
  rendered clicks carry explicit input and enum indices.

## Bad

- Step ID and semver syntax before the action selector.
- An action list that includes behavior unavailable on one selected target.
- Review and canonical JSON before the editable workflow on a phone.
- Showing a concurrency value in sequential mode where it does nothing.
- A Cancel editing link in the lifecycle rail that only navigates back.
- Removing advanced fields to make the editor look simpler.
- Stretching an ID, type, Yes/No selector, and visibility selector into four
  equally weighted boxes merely because the card has room.
- Hiding a normal default or validation bound behind a disclosure to make the
  card shorter.
- Replacing a removed disclosure with a one-off heading and horizontal rule, or
  giving adjacent rows in one group unrelated right edges.
- Capping both a form collection and its field rows, leaving an unused rail
  inside every card.
- Adding a Behavior legend when Type, Required, Sensitive, Default value, and
  bounds already explain the sequence.
- A generic text field for boolean or numeric defaults.
- A separate free-text enum default that can differ from every allowed value.
- A selected default or ordinary option wearing green pass/allowed chrome.
- Unequal Required and Sensitive widths, a shorter monospace ID control, or a
  repeated-row action aligned above the control it changes.
- A bordered row toggle beside a bare peer icon, or `phx-value-value` on a
  button whose native empty value silently replaces the intended metadata.

## Enforced

Rendered LiveView tests pin the section and field order and assert that
runtime-relevant controls remain present only in applicable modes and redundant
Cancel editing navigation is absent. Catalog tests assert that target selection
narrows compatible actions. Screenshot review covers the desktop split and the
narrow stacked layout. Shared repeating-list controls merge caller classes so
their spacing remains part of the collection contract.

Sweep complex editors for ID/version fields before behavior, behavior choices
that are not derived from earlier scope choices, controls shown in modes where
they have no effect, lifecycle rails that duplicate existing exit navigation,
breakpoint ordering that puts a secondary rail before the primary task, and
unbounded collections or uniform grids that make short finite choices as
visually heavy as primary identity or purpose fields, mismatched group edges,
unequal peer toggles, generic default controls that ignore the selected type,
enum defaults authored outside the allowed-value rows, typography that changes
peer control heights, semantic accent classes used only to mark an ordinary
in-form selection, repeated-row actions aligned to wrapper space rather than the
control box, headings that restate their field labels, and dividers that merely
preserve a removed disclosure's shell. Sweep button event metadata for generic
`phx-value-value`, and repeated rows for mismatched peer enclosures. Rendered
tests pin selected authoring controls to neutral classes and reject semantic
brand classes inside them. Sweep capped form collections for a second inner
`max-w-*` around card fields; rendered tests pin one page-level cap and reject
the nested field cap.
