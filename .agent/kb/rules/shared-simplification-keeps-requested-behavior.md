# A simplification pass keeps the behavior someone asked for

**Rule.** Before an over-engineering or simplification review ranks code as
disproportionate, trace why it exists: the commit that added it, its task, and
any rule it cites. A user-visible outcome the founder asked for is a product
requirement however much machinery it takes. The review may propose a simpler
way to deliver the same outcome, proven equal on the surface it serves, but it
never deletes the outcome. A cut that changes what a user sees or can do is a
founder decision: list it as a question, never ship it inside a cleanup batch.

**Why.** On 2026-09-02 the founder asked for the emails to stay dark in both
Gmail themes, and the Gmail-only CSS that did it was confirmed on the founder's
phone. On 2026-09-03 an over-engineering review ranked it "disproportionate
pre-v1 maintenance" ("pixel parity is not a v1 product requirement"), and a
cleanup batch deleted it together with its rule and its guard test, so nothing
was left to object. Three weeks later the founder found every email turned light
in Gmail on iOS, and the devices had to be rebuilt
(`portal/.agent/kb/rules/design-emails-survive-forced-dark-mode.md`).

**How to apply.**

- Read the introducing commit's message and task before ranking an item. If
  either says the user asked for the behavior, the item is "keep, or simplify
  with proof of the same result", never "delete".
- A deletion that removes user-visible behavior goes to the founder as a
  decision with the evidence, not into the batch.
- Deleting a guard test together with the behavior it guards is the tell: the
  test was the record that someone wanted it.
