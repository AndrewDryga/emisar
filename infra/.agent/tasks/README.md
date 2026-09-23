# The task queue

The queue's layout, states, templates, and lifecycle are identical in every
project, so they are documented once at the repository root:

[`.agent/tasks/README.md`](../../../.agent/tasks/README.md)

This file is a pointer on purpose: one copy is one thing to keep true, and
`./run check agent-setup` scans only the root copy for stale commands.
