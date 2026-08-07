# The task queue

The queue's layout, states, templates, and lifecycle are identical in every
project, so they are documented once at the repository root:

[`.agent/tasks/README.md`](../../../.agent/tasks/README.md)

This file is a pointer on purpose. Six byte-identical copies drifted — they all
still named `/spec` and `/sweep` months after those skills were renamed — and
nothing scanned them, because the stale-command check reads the manuals, not
this file. One copy is one thing to keep true.
