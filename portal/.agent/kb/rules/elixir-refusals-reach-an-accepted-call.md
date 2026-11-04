# A refusal leads to an accepted call

**Rule.** A caller who does what a refusal says must be able to reach an accepted call, and a refusal
blames only what is wrong. It never asks for two arguments that exclude each other, never asks for
one that collides with a supplied argument without naming that argument, never hides a collision
behind another problem, and never blames a field that is fine for the alternative the caller chose.

**How.** JSONSchex reports the errors of every failed alternative together, so a union cannot give a
precise refusal:

- Model a choice between shapes as one `if`/`then` per alternative, with the discriminator under
  `required` in the `if`, not as `oneOf` or `anyOf`.
- Write a field that does not apply to an alternative as `{"not": {}}`. Avoid a bare `false` subschema
  in anything `tools/list` publishes, because client schema walkers may not expect one.
- Write a nullable value as `"type": ["null", "string"]`.
- A `oneOf` of bare `required` branches is the one union to keep: it declares "exactly one of", and
  `InputContract` turns it into `one_of` issues. `Compiler.exclusive_groups/1` and
  `Compiler.required_alternatives/1` read these rules from the schema, so a new rule needs no second
  declaration.

`EmisarWeb.MCP.InputContractTest` follows every refusal for every combination of every tool's
arguments, and `Emisar.Runbooks.DefinitionTest` refuses a union in the definition schema. When
reshaping a schema, record accept or refuse for a large set of calls before and after: the decisions
must not change.

**Why.** A model retries on what a refusal tells it. In 2026-11, 648 argument combinations across 5
tools gave advice that could only be refused next, such as `wait_for_run` with neither id asking for
both. A literal runbook binding missing `value` was also told that `source` was unsupported and `ref`
was required.
