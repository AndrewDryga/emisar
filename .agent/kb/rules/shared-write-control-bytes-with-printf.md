# Write control bytes with printf, never inline in an edit or heredoc

**Rule.** Produce a control character (ESC, BEL, NUL) in a file, fixture, or
prompt with `printf '\033'` / `printf '\x1b'` — never by pasting the raw byte
into an editor tool call or a `<<EOF` heredoc. When a JSON document needs the
escape as TEXT, write the six printable characters backslash-u-0-0-1-b, and
verify which form landed with `od -c` before asserting on it.

**Why.** Raw bytes survive some tool paths and are interpreted in others, so
the failure is silent until an assertion or parser trips. Two incidents in one
loop task (2026-08-01) each burned turns: an edit meant to assert the
six-character literal landed a raw ESC byte in a test fixture, and a consult
prompt picked up a control character and had to be rewritten through a file.
The rule reproved itself while being written — its own first draft embedded raw
ESC bytes and was rejected by the editing tool.
