# Surface Modes

Choose one primary mode before writing. The house voice stays recognizable, but
the reader's job changes. Do not make documentation sound like a landing page or
make product errors sound like a blog post.

## Marketing Website

**Reader job:** decide whether this product is relevant, different, credible,
and worth the next step.

**Questions the page must answer:**

1. What is this, and is it for me?
2. What useful difference does it make?
3. How does it work?
4. What proves the claim?
5. What honest objection remains?
6. What can I do next?

Answer these somewhere in the order the argument needs, not as a fixed section
sequence. Use informative headlines, short paragraphs, and descriptive links.
Front-load important words because readers scan.

Match search intent by answering the query in human language, then earn depth
with mechanisms, comparisons, and proof. A CTA should name the natural next
step, not manufacture urgency.

Use humor sparingly in comparisons, examples, or a sharp aside. Keep it out of
security promises and buying pressure.

Avoid:

- company autobiography before reader value
- fake urgency and conversion tricks
- SEO phrases that a person would not say

## Product UI

**Reader job:** understand state, make a decision, and complete an action without
surprises.

Use the shortest wording that remains specific. Prefer familiar verbs for
buttons, concrete nouns for labels, and state plus consequence for confirmation
copy. Keep terminology identical across the UI and docs.

An error should answer:

1. What happened?
2. What is the current state?
3. What can the operator do next?

Do not use humor in errors, destructive actions, approvals, access controls,
security events, billing problems, or offline states. Do not hide a consequence
inside friendly language.

Avoid:

- `Oops`, `Uh-oh`, or blame
- buttons labeled `Yes`, `Okay`, or `Submit` when a specific verb fits
- multiple terms for the same object or action

## Documentation

**Reader job:** learn an exact concept or complete a task correctly.

Start task pages with the outcome, prerequisites, and the shortest valid path.
Use numbered steps for a sequence. Put commands beside the step that needs them
and show the expected result where it helps verification. Explain why only when
it changes a decision, prevents a mistake, or clarifies the system model.

Use second person and active voice. Assume the reader's domain competence; teach
product-specific facts rather than general computing. Define an unfamiliar term
once through context and then use it consistently.

Humor is usually noise in reference and procedure pages. A light aside can work
in a conceptual guide, but accuracy and retrieval come first.

Avoid:

- selling the product inside instructions
- narrative introductions before prerequisites
- hidden assumptions about environment or permissions
- examples that cannot run
- unexplained output, placeholders, or failure states

## Blog And Editorial

**Reader job:** gain a useful idea, argument, lesson, or perspective worth their
time.

Lead with the tension, observation, or claim, not a generic overview of the
topic. Give the piece one thesis. Develop it through real examples, mechanisms,
evidence, consequences, and counterarguments. Let the writer make a choice and
admit the tradeoff.

**Teach before you pitch.** Explain the domain from first principles at a depth
useful to someone who never buys: how the failure happens, what authority a
credential grants, why the obvious workaround breaks, or which tradeoff cannot
be wished away. Let the product appear as an implementation of principles the
reader already understands. Test the draft by asking whether the reader could
re-derive why the product exists from the explanation alone.

In `/guides/*` pieces, hold the stricter bar in
`.agent/rules/content-guides-teach-not-sell.md`: zero product mentions in the
body (or one clearly designated section), no product-docs links standing in as
proof, and let the page chrome carry the conversion. A product drop inside the
section that is winning the reader's trust flips the genre from teaching to
brochure.

Use more narrative and rhythm than website copy, but keep the argument visible.
Headings should mark turns in thought, not satisfy a template. End when the idea
lands; do not add a recap because articles are expected to have conclusions.

Humor has more room here. Keep it relevant, brief, and consistent with the
writer's actual voice.

Avoid:

- search-summary openings
- a listicle disguised as an argument
- manufactured personal anecdotes
- generic `what this means for the future` endings

## Release Notes And Announcements

**Reader job:** learn what changed, why it matters, and whether they must act.

Start with the change and the affected user. Show the behavior, migration step,
compatibility limit, or proof that matters. Keep celebration proportional to the
news.

Avoid:

- `We're thrilled to announce`
- a long origin story before the change
- feature lists without consequences
- hiding a breaking change below promotional copy
