# `nil` is not an empty list — normalize before you enumerate

**Rule.** A value read out of a map you did not build — a stored `jsonb`
definition, a decoded payload, an API response — is normalized to a list
**once**, at the point it enters the render or the pipeline, before anything
guards it or walks it. `x["key"] || []`, bound to a name the rest of the code
reads. Never let an emptiness comparison stand in for that normalization:
`x["key"] != []` is `true` when the key is absent, so the guard passes and the
comprehension behind it receives `nil`.

## Why

`!= []` looks like a list check and is not one. It is an equality test, and
`nil == []` is `false`, so a missing key reads as "non-empty" and flows
straight into `Enum.map/2` or a `:for` — `Protocol.UndefinedError: protocol
Enumerable not implemented for Atom ... Got value: nil`. In a LiveView that
raises inside `Phoenix.LiveView.Diff.traverse/6`, which takes the whole page
down rather than degrading one section.

The trap is that the guard *reads* as the safety. A reviewer sees an emptiness
check immediately above the comprehension and stops looking. Two expressions
that must agree about the same value are evaluated separately, and only one of
them handles nil.

This is specifically a hazard for **stored** data. A schema contract validated
on the way in does not constrain what is already in the column: emisar's
`Runbooks.Definition.validate_draft_shape/1` requires `"inputs"` and requires
it to be a list, but rows published under an earlier shape are never
re-validated on the way out. The run page read `runbook.definition` — raw
stored `jsonb` — and crashed on every render for those runbooks
(`Protocol.UndefinedError`, 49 events before it was found). The same module's
`pending_input_ids/3` already carried a function clause for exactly that
shape; the helper handled it, the template did not.

So "the contract requires this key" is not a reason to skip normalizing. The
contract governs writes. You are reading.

## ✅ Good

Normalize once, into a name, and let both the guard and the walk read it:

```elixir
defp run_form(assigns) do
  assigns = assign(assigns, :inputs, assigns.runbook.definition["inputs"] || [])

  ~H"""
  <div :if={@inputs != []} class="grid gap-4 sm:grid-cols-2">
    <div :for={input <- @inputs}>
  """
end
```

Or normalize at the source, so every consumer downstream is safe by
construction — what `Emisar.RunbookDraft.from_definition/1` does, and why the
editor and workflow components can compare `draft["inputs"] == []` freely:

```elixir
%{
  "context_markdown" => definition["context_markdown"] || "",
  "inputs" => Enum.map(definition["inputs"] || [], &input_from_definition/1),
  "stages" => Enum.map(definition["stages"] || [], &stage_from_definition/1)
}
```

A pattern-matched clause is equally good where the read is a function:

```elixir
defp pending_input_ids(%{"inputs" => declarations}, raw, touched)
     when is_list(declarations) do
  ...
end

defp pending_input_ids(_definition, _raw, _touched), do: []
```

## ❌ Bad

The guard and the enumerable read the same raw expression twice, and neither
handles nil:

```heex
<div :if={@runbook.definition["inputs"] != []}>
  <div :for={input <- @runbook.definition["inputs"]}>
```

Also bad, same defect without a template — the `if` reads as protection and
is not:

```elixir
if payload["items"] != [], do: Enum.map(payload["items"], &row/1), else: []
```

## Scope — when `!= []` is correct

On a value you normalized, or that a constructor guarantees, comparing to `[]`
is right and this rule does not apply. The 11 live uses of `x["key"] != []` in
`emisar_web` are all of that kind — `draft["inputs"]`, `step["outputs"]`,
`input["enum_values"]` — reading a draft that
`RunbookDraft.from_definition/1` already normalized. Do not "fix" those; the
tell is not the comparison, it is whether the value came from a map **you**
built.

## How it's enforced

`EmisarWeb.TemplateHygieneTest` — "a comprehension does not re-read a raw
subscript its guard already tested" — fails when a `:for` walks a subscript
expression (`something["key"]`) that the enclosing element also compares to
`[]`. It lives there, not in `credo/checks/`, because **Credo cannot see inside
a `~H` sigil**: the template body is a binary literal at parse time, so the
expressions in `:if={…}` and `:for={…}` are text, not AST. The crash this rule
exists for was inside a `~H` sigil.

The broad AST form — flag every `x["key"] != []` — was measured and
**rejected**: it fires on 11 sites in `emisar_web` and all 11 are correct. See
[`elixir-rejected-credo-checks.md`](elixir-rejected-credo-checks.md) §6.

## Sweep target

Two greps, and the second is the one that matters:

```sh
# 1. Raw stored maps reaching a comprehension — read each, confirm the value
#    was normalized somewhere upstream.
grep -rnE '(:for=\{[^}]*<-|Enum\.[a-z_]+\()[^)}]*\["[a-z_]+"\]' \
  --include='*.ex' --include='*.heex' apps/*/lib

# 2. An emptiness guard on a subscript read — correct on normalized data,
#    a nil trap on anything stored.
grep -rnE '\["[a-z_]+"\] (!=|==) \[\]' --include='*.ex' --include='*.heex' apps/*/lib
```

For each hit, answer one question: **who built this map?** If the answer is a
database column, a decoded request body, or a third-party response, normalize
it. If it is a constructor in this repo that always fills the key, leave it.
