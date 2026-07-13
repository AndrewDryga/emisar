---
name: ops-release
description: Cut an emisar product release end to end — changelog, version, license date, gate, commit, signed tag, push, and GitHub release. Use when the user asks to cut or publish a product release.
effort: medium
argument-hint: "[vX.Y.Z] [anchor-commit]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Cut a release

Read [`docs/release.md`](../../../docs/release.md) in full and execute that
canonical runbook in order. Cross-read the current changelog entries and use
`/content-director` for both the plain-text website summary and the Markdown
GitHub release notes.

Do not duplicate or improvise the release procedure here. The invariants are:

- product tag, changelog entry, `portal/VERSION`, and anchor describe one window;
- `LICENSE.md` carries that release's three-year BUSL Change Date;
- tags are signed and verified before push;
- the complete portal gate is green before the release commit;
- every `git push`, tag push, and `gh release create` requires explicit user
  confirmation because it leaves the machine.

After publication, verify the signed tag, GitHub release, changelog page/feed,
and any release workflow triggered by the tag, then record the result in the
local portal agent log.
