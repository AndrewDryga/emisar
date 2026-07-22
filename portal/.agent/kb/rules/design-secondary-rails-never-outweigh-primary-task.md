# Secondary rails never outweigh the primary task

## Rule

A fixed-width secondary rail may appear beside a task only when the remaining primary
column is visibly wider. Otherwise, keep one column and place the rail after the task.

Move every rail-dependent behavior at the same breakpoint: grid tracks, sticky
positioning, ordering, top margins, and visibility. A rail that becomes sticky or visible
before its grid splits recreates the same imbalance in a different form.

## Why

Console pages already lose viewport width to navigation. Splitting a `22rem` or `340px`
rail at `lg` can leave the task with less usable space than explanatory or decision
content. That reverses the page hierarchy and makes forms, code lines, and records feel
cramped at ordinary laptop widths.

## Good

```heex
<div class="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_22rem]">
  <main>...</main>
  <aside class="mt-10 xl:mt-0 xl:sticky xl:top-6">...</aside>
</div>
```

At the narrowest split viewport, confirm the task is still wider than the rail. At the
viewport immediately below it, confirm the task leads and the rail stacks without
overflow or an ordering jump.

## Bad

```heex
<div class="lg:grid lg:grid-cols-[minmax(0,1fr)_22rem]">
  <main>...</main>
  <aside class="lg:sticky lg:top-6">...</aside>
</div>
```

The breakpoint name alone does not guarantee enough content width once console chrome,
container padding, and the inter-column gap are subtracted.

## Sweep

Search LiveView and component templates for fixed secondary tracks such as `22rem` and
`340px`, especially those introduced at `lg`. Inspect each layout rather than replacing
breakpoints blindly: peer columns and intentionally narrow task surfaces are different
patterns.

## Enforcement

Review-enforced. Available task width depends on the surrounding shell and cannot be
reliably inferred from a class string. Browser verification must cover the narrowest
two-column viewport and one viewport below the split, on both short and long states.
