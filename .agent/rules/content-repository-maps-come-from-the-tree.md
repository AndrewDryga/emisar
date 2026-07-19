# Repository maps come from the tree

## Rule

Before describing a repository area, inspect the area itself. Enumerate its
tracked files and commands, read its owner `AGENTS.md` and `README.md`, and use
the language toolchain's package listing when it reveals responsibilities that
filenames do not.

Summarize the current ownership those sources establish. Preserve facts that
change how a reader treats the code, including whether infrastructure is live
production configuration and whether a directory serves product authors as
well as maintainers. Do not infer a narrower role from the first recognizable
file or soften production code into a reference example.

## Why

A repository map is a routing contract. Contributors use it to decide where to
work, which instructions apply, and how cautiously to handle a directory. An
invented or incomplete label sends work to the wrong place and can make live
infrastructure look disposable.

## Good

- Verify a directory with `git ls-files`, `find`, `rg`, and the relevant package
  or command listing before reducing it to one line.
- Name live production ownership directly when the owner documentation does.
- Include distinct primary jobs, such as pack-authoring support, repository
  checks, and end-to-end drivers, when the directory owns all three.
- Sweep repository layouts, architecture overviews, and contributor routing
  tables for the same stale description.

## Bad

- Call deployed infrastructure a reference stack because the Terraform is
  readable as an example.
- Describe a mixed-purpose tools module as maintainer-only after inspecting only
  its CI command.
- Copy an old repository map into a new README without checking the current
  tree.

## Enforcement

Apply this rule in content review and include the verification commands in the
task log. `doccheck` can enforce link integrity, but semantic ownership cannot
be validated reliably with a keyword grep. Do not add a source-text check that
would accept a polished but still incomplete description.
