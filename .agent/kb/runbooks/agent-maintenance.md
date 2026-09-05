# Maintaining agent instructions

Use this when upgrading models or changing manuals, skills, or orchestration.
Review date: 2026-09-05.

## Instruction ownership

AGENTS.md owns shared scope, authorization, verification, and worktree rules.
Project manuals own engineering invariants and route to detailed references.
Search rule indexes and read matching entries without loading every rule. Skills
describe the specific workflow and inherit user authority. Preset YAML owns
model/effort targets; role prompts own duties.

The root plus any one project manual fits Codex's default 32 KiB project-document
budget, including their separator. This repository check does not account for global
instructions or client overrides. Keep essential security invariants in the manuals
and link relevant detail. `agentcheck` checks bytes and retained rule discovery.

## Model changes

Read current official guidance for the exact model. Check CLI and account support
with `coop models <agent> --refresh` and a bounded, tool-free probe before changing
defaults. The menu is discovery, not validation: Coop passes model IDs and effort
values through to the provider CLI.

Keep worker and evaluator cost/quality roles separate from frontier reasoning.
Start with the existing effective effort; Fable 5.1 recommends high, then measuring
other levels. Model availability does not prove improved task outcomes. Compare
representative work for completion, unnecessary questions, scope drift, verification,
elapsed time, and cost before further effort or routing changes.

An existing Coop image can contain older clients than the host. Inspect its Claude
and Codex versions before using new targets. `coop update --box-only` refreshes
base/project images without updating the Coop binary; it restarts supervised ACP
sessions, while running loop and interactive boxes keep their image until restarted.
Check active sessions and scope before refreshing shared runtime state. Fable 5.1
needs Claude Code 2.1.255 or later. Verify the resulting image and model selection.

Prompt changes can improve progress updates, independent tool-call batching,
targeted edits, and completion. API history binding, progress-block display,
streaming, timeouts, and compaction transport belong to the client/harness. An
AGENTS.md edit does not implement those capabilities; changes to a sibling client
repository need their own scope.

## Behavioral review

After changing shared workflow skills, use an independent read-only review with
realistic requests and the new instructions, without providing expected verdicts:

- A question about a bug while unrelated todo tasks exist.
- An authorized three-file fix with a routine design choice.
- A failing focused test followed by a repair within the requested scope.
- A delegated patch with focused checks and a final gate still required.
- A confirmed-unrun migration versus one already applied in production.
- A resumed session with an accepted decision and completed verification.
- A code change whose deployment still requires separate authority.

Inspect the actions the reviewer would take. An instruction-only review is not a
coding benchmark. Keep security, denial/isolation coverage, applied migrations,
and one-writer ownership intact. Run `./run check agent-setup` and
`./run gate tooling`, plus other touched project gates. Inspect moved anchors as
well as file links.

## Sources

- [GPT-6 Astra guidance](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
- [Codex instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Fable 5 prompting](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5)
- [Fable 5.1 prompting](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
