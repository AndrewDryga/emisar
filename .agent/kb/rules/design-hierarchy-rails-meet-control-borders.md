# Hierarchy rails meet control borders

## Rule

A visual tree connects real control geometry. Align the parent trunk to the
parent checkbox center, begin it at the checkbox edge, branch horizontally to
each child checkbox's near border, and stop the trunk at the final child
midpoint. Never draw a connector underneath an interactive control. Render
rails one contrast step quieter than control borders.

Differentiate parent rows from children with a quiet surface and type step.

## Why

An approximate margin creates a decorative line rather than a hierarchy. A rail
that misses the parent, never branches to children, continues beneath a
checkbox, or runs below the final row makes the controls look misplaced.
Indentation alone is also too weak when parent and child labels share the same
size, weight, and surface.

## Good

- Parent checkbox center and trunk share the same x-coordinate.
- The trunk touches the parent checkbox and ends at the final child midpoint.
- Every child branch stops at the checkbox border.
- Connector rails recede behind checkbox borders instead of matching them.
- Parent rows use a subtle surface step and stronger label.
- Child labels sit one type step below their parent.

## Bad

- `ml-[1.4rem] border-l` approximates a checkbox position.
- The rail starts below the parent with a visible gap.
- Children float beside a trunk with no elbow or branch.
- A branch continues beneath a checkbox to its center.
- Connector rails use the same contrast as interactive control borders.
- The trunk continues to the bottom of the container.
- Parent and child labels have indistinguishable hierarchy.

## Enforced

The shared runner-scope component test pins the 20px parent-center geometry,
12px child-border branch, subdued connector contrast, last-row termination, and
parent/child visual tiers. Desktop and mobile screenshot review verifies the
rendered alignment.

## Sweep target

Search for indented `border-l` trees and inspect whether the rail derives from
the actual checkbox/control dimensions. Search pseudo-element branches for
widths that extend beneath the control instead of ending at its near border.
Compare rail color and opacity with the connected control border; the rail must
be visibly quieter.
