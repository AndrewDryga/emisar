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
changes execution. Reserve the conditional bound's grid track so hiding it never
resizes fields that precede its trigger. Put a workflow unit's identifier in its
overview: a stage pairs it with its title, while a step leads with its compact
identifier before targets and action. Keep infrequently changed limits in a
nearby disclosure after the behavior they refine.

Inside a repeated form card, visual weight and row order follow the decisions an
operator makes. Pair identity with purpose, put behavior choices next, then show
conditional values, defaults, and bounds. Field labels carry the hierarchy when
that order is already clear; do not add a group heading merely to restate it.
Let flexible text fields grow only to a readable measure, keep finite choices at
a content-sized width, and use the shortest unambiguous label for a finite choice
or bound so its track does not steal width from the flexible field. Cap the
collection on wide canvases. Intentional negative space is better than stretching
controls to fill a uniform grid. Give related rows one measure and right edge.
The collection or card owns that measure; do not add a second inner width cap
that leaves a dead rail inside the card. Inside a row, equal binary choices use
the same compact width while the domain-bearing choice takes the remaining
space. Font treatment must not change peer control heights.

Field rows express one relationship at a time. Keep identity beside visibility,
then put a transformation chain or condition in left-to-right reading order on
one desktop row. A mode or behavior selector that governs the row gets more
width than bounded numeric inputs; the compact inputs still share the same
baseline and enclosure. Reserve tracks for conditional peers, or attach a tail
control on the next row, so revealing one never resizes the controls before it.
Stack the same order on narrow screens.

A repeated contract row translates schema metadata into operator language. Lead
with the stable argument name, summarize requirement and type as a phrase
(`Optional JSON value`, not `file · json · optional`), then present labeled source
and value controls. Hide the value control when the operator omits an optional
argument; do not replace it with explanatory filler. Scope and action controls
must stand on their labels, choices, and validation state. Supporting prose earns
its place only when it changes the decision rather than narrating behavior already
enforced by the form.

A multi-target control keeps one stable-height trigger in the workflow overview.
The trigger summarizes the current selection; its menu owns both addition and
removal. Never stack selected-target rows above a second picker in the overview
grid. When a saved target no longer resolves, name it in operator language,
mark it unavailable in the trigger, and keep its menu row removable even when
there are no current targets to add.

A dependent control does not invent a second failure while its prerequisite is
unresolved. Keep its saved value visible, neutral, and disabled so the operator
can understand what will become editable after fixing the prerequisite. The
prerequisite owns the actionable error. Only mark the dependent choice
unavailable or incompatible after its prerequisite resolves and that evaluation
actually fails.

A compact overview row keeps one geometry as validation changes. When a control
already carries its invalid state or unavailable label, attach the explanation
and remedy through the shared accessible tooltip instead of inserting a
conditional paragraph beneath that column. Keep an inline error only when the
message itself is the primary, always-visible correction surface.

A secondary boolean qualifier inside a repeated row uses a compact positive-state
checkbox when unchecked means its normal absence. Label the true state directly
(`Sensitive`), keep ordinary authoring selection neutral, and post an explicit
false value when unchecked. Do not spend a select and field heading on
`Visible/Sensitive` when the row only needs one sensitivity flag. Primary
decisions where both alternatives need names may keep their existing control.

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
and Publish. Self-labeling lifecycle controls need no generic `Actions` heading.
On a desktop rail, put editable details first, then lifecycle metadata and
controls immediately before the validation panel they govern. Do not add a
Cancel or Back action there when it only duplicates the page header or
application navigation.

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
  and applicable concurrency bound on one wide row; hiding the bound leaves the
  earlier tracks unchanged, and narrow screens preserve the same order while
  stacking.
- A step overview puts its compact identifier before targets and an action
  compatible with all selected runners. The pack follows the action automatically.
- A multi-target step keeps one aligned Targets trigger. `edge-web group` is
  shown instead of `group:edge-web`; an unavailable saved target is visibly
  invalid and can still be removed from the same menu.
- When Targets cannot resolve, Action keeps its saved action name in a neutral
  disabled control and shows no compatibility error. Once Targets resolve, a
  genuinely incompatible action owns its unavailable label and accessible
  tooltip remedy without moving the Arguments section below it.
- An argument named `file` reads `Optional JSON value`, then shows `Use` and the
  applicable value control. Choosing Omit leaves only the compact source control.
- Parallel stages show a concurrency cap; sequential stages do not.
- A secondary review rail becomes sticky only when it sits beside a visibly
  wider task column; otherwise it follows the workflow.
- Save and Publish stay together; the existing page navigation remains the one
  way to leave the editor.
- Details lead the desktop rail; lifecycle metadata and the self-labeling Save
  and Publish controls sit immediately before Publish check without an `Actions`
  heading.
- A run-time input pairs ID with description; then type, required, and sensitive;
  then enum values when applicable; otherwise its default and applicable lower
  and upper bounds share one row.
- An extracted output pairs its flexible ID with a compact neutral Sensitive
  checkbox, then reads Read from, Extract with, Expression across one row. A
  condition reads Output, Must be, Expected JSON value on one row.
- Retry policy reads behavior first, then compact interval, timeout, and maximum
  observation controls on the same row. Conditional numeric tracks remain
  reserved while retry is off.
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

- A step identifier detached in a disclosure after Targets and Action.
- An action list that includes behavior unavailable on one selected target.
- A later conditional field that resizes an earlier title when toggled.
- Schema-tuple copy such as `file · json · optional`, an unlabeled pair of binding
  controls, or filler explaining that Omit omits the value.
- Help text under Targets or Action that only restates ordering, compatibility, or
  pack resolution already enforced by those controls.
- Selected-target cards stacked over an add-target dropdown, raw tagged refs in
  the closed trigger, or a stale target that becomes impossible to remove when
  the live catalog is empty.
- An unresolved target that also turns Action rose, prefixes it with
  `Unavailable`, or claims runner compatibility failed when compatibility could
  not be evaluated.
- A conditional validation paragraph beneath one overview control that makes
  the row and every following section jump when the error appears or clears.
- A repeated output qualifier stretched into a `Visible/Sensitive` select when
  one neutral Sensitive checkbox expresses the same boolean.
- Review and canonical JSON before the editable workflow on a phone.
- Showing a concurrency value in sequential mode where it does nothing.
- A Cancel editing link in the lifecycle rail that only navigates back.
- A generic `Actions` heading above self-labeling Save and Publish controls, or
  unrelated panels separating those controls from their publish check.
- Removing advanced fields to make the editor look simpler.
- Stretching an ID, type, Yes/No selector, and visibility selector into four
  equally weighted boxes merely because the card has room.
- Breaking one transformation, condition, or retry relationship across rows when
  the desktop card has room, or giving short numeric bounds the same width as
  their governing behavior selector.
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

Sweep complex editors for ID/version fields detached from the workflow overview,
behavior choices that are not derived from earlier scope choices, controls shown
in modes where they have no effect, conditional fields whose presence changes the
width of fields before their trigger, lifecycle rails that duplicate existing
exit navigation, generic headings above self-labeling controls, controls
separated from the validation panel they govern, breakpoint ordering that puts
a secondary rail before the primary task, and unbounded collections or uniform
grids that make short finite choices as
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
the nested field cap. Sweep repeated contract rows for delimiter-joined schema
metadata, unlabeled source/value controls, and explanatory placeholders standing
in for a hidden inapplicable control. Sweep repeated operational cards for
desktop relationships split across rows, finite controls stretched to equal
weight, and conditional fields that resize earlier tracks instead of using a
reserved track or attached continuation. Sweep workflow overview scope controls
for selected items stacked outside their picker, raw `group:`/`runner:` refs,
and stale selections whose remove action is disabled with the add catalog.
Sweep scope-first forms for a dependent behavior control that repeats the
prerequisite's error or claims its own compatibility result before the
prerequisite resolves. Rendered tests pin the neutral disabled dependency state
and retain a separate true-incompatibility case. That case pins the accessible
tooltip and rejects a flow paragraph inside the overview, while screenshot
review checks desktop and narrow geometry. Sweep compact overview grids for
conditional validation paragraphs that change row height. Sweep repeated
operational rows for secondary false/true selects that should be positive-state
checkboxes; rendered tests pin the hidden false value, checked true value,
neutral tone, and compact track.
