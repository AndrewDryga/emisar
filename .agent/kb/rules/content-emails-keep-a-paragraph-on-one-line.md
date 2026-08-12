# Rule — an email paragraph is one line

**A plain-text email body carries newlines for STRUCTURE only.** One paragraph is
one line, however long: a blank line separates blocks, a code or URL sits alone on
its line, and a label/value block is indented two spaces with `Label:` keys. Never
wrap a sentence in the source.

## Why

A mail client re-wraps a long line to the width it actually has — phone, split
pane, or a 1400px window. It can never undo a newline we sent.

Interpolation is what makes a source wrap indefensible rather than merely
old-fashioned: the author wraps around a *placeholder*, and the recipient reads
the *value*. `#{inviter.full_name || inviter.email}` is 37 characters of source
and 12 characters of "Andrew Dryga", so the invitation's opening line broke after
`invited you to join the` — 36 characters into a 64-character sentence, with the
workspace name orphaned onto its own line. Nobody chose that column; the source
did, at a width the reader never sees.

The same applies to fixed text, just less visibly: a paragraph wrapped at 72
columns renders as a ragged short-line block in a wide window, and re-wraps
raggedly again on a narrow one, because the client wraps our already-wrapped
lines.

## ✅ Good

```elixir
deliver(user.email, "Confirm your emisar account", """
Welcome to emisar!

Confirm your email to finish setting up your account:

#{url}

You can sign in any time — emisar emails you a one-time link, no password to set:

#{sign_in_url}

— emisar
""")
```

```elixir
# Structure, not prose: a code indented four, a label/value block indented two.
"""
    #{secret}

This sign-in was requested:

  Time:   #{time}
  From:   #{ip}
"""
```

## ❌ Bad

```elixir
"""
#{inviter.full_name || inviter.email} invited you to join the
\"#{account.name}\" workspace on emisar.

You can sign in any time — emisar emails you a one-time link, no password
to set:
"""
```

Both paragraphs break at a column derived from the source, not the reader's
window — the first one 36 characters in.

## Scope

Plain-text bodies. An HTML alternative is free to wrap wherever it likes: its
newlines are collapsed to whitespace, and `<p>`/`<pre>` carry the structure. But a
value shared between both bodies (a `request_details`-style block landing in a
`<pre>`) keeps its indent modest, because a `<pre>` does not re-wrap either.

Credo's `MaxLineLength` sets `ignore_heredocs: true` and `ignore_strings: true`,
so a one-line paragraph in a heredoc is not a line-length finding. Nothing in the
formatter reflows heredoc content either — the layout you write is the layout that
ships.

## How it's enforced

`Emisar.Mailers.TextLayoutTest` (portal) renders every transactional email we send
and asserts each prose line both starts and ends a sentence — the two halves a
source wrap always leaves behind. Structure is exempt by shape: blank lines,
indented blocks, ALL-CAPS eyebrows, lines carrying a URL, and the `— emisar`
signoff. **A new email must be added to that test's `bodies/0`**; the contract only
covers what it renders.

## Sweep

Any multi-line prose paragraph inside a string that reaches `text_body` — grep the
mailers for a heredoc line that ends without terminal punctuation, or one that
begins in lower case.
