# Complex editors follow decision order

## Rule

Order a complex editor by the decisions an operator makes:

1. name the thing and state its intent;
2. supply shared context and run-time inputs;
3. build the workflow in execution order;
4. review and publish.

Inside a workflow unit, choose behavior before implementation detail. An action
comes before its target; execution mode comes before its concurrency bound.
Stable identifiers, version constraints, and infrequently changed limits stay in
a nearby disclosure after the behavior they refine.

Do not hide a control merely because another mode changes how strongly it
applies. If it still changes execution, keep it visible and explain the
interaction. On narrow screens, the primary editing workflow renders before
review, canonical output, or other secondary rails.

## Why

Schema order is optimized for storage, not authoring. Leading with identifiers
and compatibility syntax forces an operator to solve implementation details
before they have chosen what the workflow should do. Hiding a live execution
control creates a worse failure: the saved behavior changes without a visible
way to understand or edit it.

Progressive disclosure is appropriate for stable detail, not for behavior. The
goal is the complete model with fewer simultaneous decisions, never a reduced
model.

## Good

- Details, context, inputs, stages, then publish review.
- Pack, action, target mode, and targets; version requirement and step ID follow
  in a disclosure.
- Sequential and parallel stages both show the concurrency cap because runner
  fan-out still uses it.
- A secondary review rail becomes sticky only when it sits beside a visibly
  wider task column; otherwise it follows the workflow.

## Bad

- Step ID and semver syntax before the action selector.
- Review and canonical JSON before the editable workflow on a phone.
- Hiding a concurrency value in sequential mode even though it still caps
  runner fan-out.
- Removing advanced fields to make the editor look simpler.

## Enforced

Rendered LiveView tests pin the section and field order and assert that
runtime-relevant controls remain present in every applicable mode. Screenshot
review covers the desktop split and the narrow stacked layout.

Sweep complex editors for ID/version fields before behavior, conditional fields
whose value still affects runtime, and breakpoint ordering that puts a secondary
rail before the primary task.
