---
name: workflow-work
description: Complete an authorized Emisar implementation with focused feedback, canonical final gates, and scope discipline. Use for a plan, checklist, or request to implement or continue work.
effort: high
argument-hint: "[plan, or 'continue']"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Complete the implementation

Follow the root and touched project AGENTS.md. The user's request or accepted plan
defines the complete deliverable. Use workflow-spec when design is needed, then
continue under the existing authorization.

Work in coherent steps. Give concise updates about findings and the next check.
Use Elixir context/testing skills for Portal, go-engineer for runner/MCP, and
security-engineer for trust boundaries. Verify unfamiliar APIs against source or
documentation before using them.

Run focused checks for the behavior being changed. For Portal, use focused Credo
after coherent Elixir edits and relevant ExUnit tests. Keep required happy, denial,
cross-account, and abuse cases. Fix a red check before dependent work; gather missing
evidence and repair within scope instead of stopping at the first failure.
Never weaken an assertion or gate to hide a defect.

Adapt routine implementation details as evidence develops. Preserve the full agreed
behavior and security contracts. For a material scope or authority change, complete
independent work and ask for that decision. Nearby unrelated issues belong in a
follow-up. Use targeted edits unless most of the file is changing.

The lead reviews delegated changes and runs each touched project's canonical
`./run gate <project>` on the final tree. Delegates provide focused check evidence;
a handoff does not itself require duplicate full gates. Rerun or broaden verification
after changes, failures, or unresolved concerns. Agent/tooling work also requires
`./run check agent-setup` and `./run gate tooling`.

Finish the lifecycle required by AGENTS.md: focused commit, task notes, and
completion state. Report actual outcomes and validation, distinguishing source
completion from push, deployment, and live proof. Preserve pending work and user
decisions across compaction. Do not end with a promise to perform an authorized
step that remains undone.
