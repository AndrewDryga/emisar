# Voice And Tone Rules

Read this before writing anything longer than a label.

## House Voice

Write like a technically literate professional talking to a capable friend:

- confident, not absolute
- direct, not blunt for sport
- friendly, not familiar
- technically exact, not academic
- commercial, not salesy
- calm about security, not theatrical
- funny on occasion, never desperate to be funny

The voice respects the reader enough to skip the performance. It can take a
position. It does not need to sound important.

## House Positions

Use these when the subject supports them. They are arguments to explain and
defend, not slogans to paste:

The canonical positioning order and claim boundaries live in
`.agent/rules/content-position-bounded-autonomy.md`.

- **Bounded autonomy is the promise.** Let an MCP-capable agent keep working on
  infrastructure without a human shadowing every step or handing it open-ended
  production authority. Work inside policy can continue; work outside those
  bounds stops.
- **The control system makes autonomy credible.** Give agents declared actions,
  not ambient shell authority. Packs fix the executable, arguments, risk,
  limits, and redaction rules; policy and the runner enforce that contract at
  the execution boundary.
- **Approval is a branch, not the product.** Actions that policy allows should
  run without ceremony. Actions that require a human decision wait before the
  side effect. Approvals, audit, and SIEM export are necessary controls, but a
  generic approval queue is not the reason to buy emisar.
- **The catalog makes the first useful result arrive fast.** Start with the
  prebuilt action pack catalog. Host-aware suggestions help operators find the
  relevant packs instead of making them model every command before the first
  run. When size matters, cite the current pack and action counts from
  `packs/AGENTS.md` instead of using a magnitude adjective.
- **Install the infrastructure MCP integration once, then add actions.** The MCP
  tool surface stays fixed while packs add capabilities. A team can wrap its
  own operational procedures as actions instead of rolling out another MCP
  server and another client configuration.
- **Denied attempts belong in the record too.** The audit trail records denials
  and pending approvals, not only successful execution.

Keep the claim bounded. emisar gives an agent a constrained action surface; it
does not run the agent loop, turn production into a sandbox, or guarantee that a
permitted destructive action cannot cause damage. The safety claim rests on the
actions, policies, pack trust, runner validation, and operator configuration in
use.

## Behavioral Anchors

Use these to learn the register, not as copy blocks. Write new lines for the
actual surface.

### Website

> Let the agent keep working. Keep production authority bounded.
>
> emisar gives MCP-capable agents a catalog of declared infrastructure actions.
> Policy decides what runs, what needs you, and what is denied; the runner checks
> the action again on the host. Start with prebuilt, host-suggested packs, then
> add your own actions without adding another MCP server.

The headline makes a choice. The body explains the choice with product behavior,
not adjectives.

### Product UI

> Runner offline. No actions were dispatched. Check the service logs, then
> reconnect the runner.

The message names the state, consequence, and next step without cheerfulness or
blame.

### Documentation

> Connect one Linux host and run `linux.uptime`. You are done when the runner is
> online and the run appears in the audit trail.

The opening states the task and its observable finish line.

### Blog

> An SSH key is a poor interface for an AI agent. It gives the model a shell and
> whatever authority the account has collected over the years. From there,
> "inspect this node" and "restart every node" are separated mainly by the
> command the model decides to type.
>
> The shell is wonderfully flexible. That is the problem.

The passage teaches the domain problem before mentioning a product. The dry line
works because it is also the technical argument.

## Write With A Point Of View

Strong prose selects the telling detail, explains cause and effect, and states
what follows. It changes pace with the idea instead of filling a template.

- Talk to one reader. Use `you` when it clarifies responsibility or benefit,
  not in every sentence.
- Use contractions when they sound natural.
- Prefer the conversational word when it is equally precise: `use`, not
  `utilize`; `before`, not `prior to`; `help`, not `facilitate`.
- Let short sentences carry emphasis. Let longer sentences connect ideas that
  genuinely belong together.
- Use transitions that express logic: `but`, `because`, `so`, `instead`.
- Include the telling detail. One real command, failure mode, limit, or example
  does more than a paragraph of praise.
- Give the reader enough first-principles explanation to judge the conclusion,
  not merely receive it.

Do not manufacture voice with typos, slang, invented stories, or arbitrary
sentence variation.

## Remove Generated Cadence

These examples are not an exhaustive blacklist. Catch the underlying pattern:
language a model could autocomplete onto almost any SaaS page.

Distrust canned frames such as:

- `In today's...`
- `At its core...`
- `Whether you're X, Y, or Z...`
- `It's not just X. It's Y.`
- `This is where X comes in.`
- a conclusion that restates the introduction

Distrust visible templates such as:

- every list has three items
- every section opens with a rhetorical question
- repeated `No X. No Y. Just Z.` fragments
- repeated contrasts built as `not X, but Y`
- consecutive sentences with the same grammatical opening

Words such as `unlock`, `empower`, `seamless`, `robust`, `transformative`,
`future-proof`, `world-class`, `comprehensive`, `powerful`, and `enterprise-grade`
often hide the real claim. They remain valid when the content states what was
tested, what failure the system withstands, or what capability the word names.

## Kill Marketing Water

A sentence earns its place by stating a fact, explaining a mechanism or
consequence, providing proof or an example, answering an objection, guiding an
action, or adding relevant personality.

Bad:

> Unlock seamless infrastructure automation with a powerful platform designed
> to help modern teams move faster with confidence.

Better:

> Give the agent a catalog of bounded infrastructure actions, then let it work.
> Policy holds the actions that need a person and denies the ones that should
> not run at all.

Delete praise and transitions when no mechanism, consequence, or proof can
replace them.

## Confidence Without Inflation

- State verified facts directly.
- Put the limit beside the claim when it changes the decision.
- Replace `can help improve` with the actual outcome when it is known.
- Do not hide uncertainty behind `may`, `often`, or `typically`. Name what is
  unknown.
- Do not turn a feature into a guarantee. Security controls contain specific
  risks; they do not make actions universally safe.
- Prefer a precise tradeoff over a perfect-sounding promise.

## Humor With A Job

Humor should reveal something true. Three useful mechanics:

- **Dry understatement:** describe an absurdly broad or painful behavior with
  calm precision. Example: "`sudo sh -c` is an impressively broad API."
- **Flagged aside:** name the tempting digression, then return to the argument.
  Example: "SSH certificate rotation deserves its own argument. Not this
  paragraph."
- **Self-aware admission:** acknowledge the awkward reality in the system or
  workflow. Example: "We would love to call this a sandbox. It is not one."

Run the deletion test. If removing the joke also removes information or useful
emphasis, it is an observation with wit. If nothing changes, keep it only when
it is genuinely funny.

Never joke at the reader's expense. Keep humor out of security warnings,
destructive confirmations, active incidents, legal terms, billing failures, and
error recovery.

## Headlines

A headline should name the product, offer, problem, mechanism, comparison, or
proof. It should remain useful when read without the paragraph below it.

Weak:

- Built for modern teams
- Move faster with confidence
- The future of secure automation

Stronger:

- Leave the agent working, not holding an SSH key
- Install one infrastructure MCP. Add capabilities as actions.
- Start with the packs suggested for this host
- Denied actions belong in the audit trail too
- The runner executes the contract, not the prompt
- High-risk actions wait before the side effect

Do not make every headline a slogan. Plain descriptive headings are correct in
docs, pricing, comparisons, and product UI.
