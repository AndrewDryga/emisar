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
changes execution. Stable identifiers and infrequently changed limits stay in a
nearby disclosure after the behavior they refine.

Do not show a control in a mode where it has no effect. If a value still changes
execution, keep it visible beside the choice it qualifies and explain the
interaction. On narrow screens, lifecycle actions may lead, but the primary
editing workflow renders before details, validation, canonical output, or other
secondary rails.

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
- Targets first; then an action compatible with all selected runners. The pack
  follows the action automatically and the step ID lives in a disclosure.
- Parallel stages show a concurrency cap; sequential stages do not.
- A secondary review rail becomes sticky only when it sits beside a visibly
  wider task column; otherwise it follows the workflow.

## Bad

- Step ID and semver syntax before the action selector.
- An action list that includes behavior unavailable on one selected target.
- Review and canonical JSON before the editable workflow on a phone.
- Showing a concurrency value in sequential mode where it does nothing.
- Removing advanced fields to make the editor look simpler.

## Enforced

Rendered LiveView tests pin the section and field order and assert that
runtime-relevant controls remain present only in applicable modes. Catalog tests
assert that target selection narrows compatible actions. Screenshot review
covers the desktop split and the narrow stacked layout.

Sweep complex editors for ID/version fields before behavior, behavior choices
that are not derived from earlier scope choices, controls shown in modes where
they have no effect, and breakpoint ordering that puts a secondary rail before
the primary task.
