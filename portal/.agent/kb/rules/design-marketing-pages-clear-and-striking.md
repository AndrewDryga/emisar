# Rule: a marketing page is clear and striking — never overloaded, never generic

**Rule.** Each section carries one idea that a stranger can read on the first pass, and
the page as a whole has a point of view a stranger remembers. Both failures are real:

- **Overloaded** (round 1): every block decorated with eyebrows, uppercase micro-labels,
  chips, badges, stat rows, grain, decorative grids, cards inside cards, dashboards of
  invented data, and several animations competing at once.
- **Generic** (round 2): everything removed until the page is a white column of text with
  a stock green button; ten "different" pages that differ only in font size and spacing.

What a good page has instead:

- **The brand's own look.** emisar is dark: near-black ground, emerald `#14cf8d`/`#36e6a5`
  brand accent, the real logo. A proposal does not switch to a light theme unless asked.
- **One signature visual idea**, ideally the product itself: a high-fidelity, legible
  recreation or real excerpt of the console, an agent session, the request path, or the
  gate. It explains the product, so it earns its size.
- **Purposeful motion.** A hero animation and small, quiet motion elsewhere (reveals,
  state changes, a live feed) that shows how the product behaves. Respect reduced motion;
  no motion that only decorates.
- **Depth used with taste.** Light, gradients, and glow are allowed when they model
  something (the gate, a focus of attention), not as texture on every block.
- **Real variety across variants.** When several directions are proposed, each differs in
  concept, composition, signature visual, and motion, not just in type scale.

**Product pictures.** Show one moment at the scale of the text around it. A full console
screen (forms, hashes, uppercase field labels, a requester's name) competes with the
argument even when it is real; an excerpt of the moment that matters (the command, the
policy line, Approve/Deny; the runs list with one waiting row) works. Never present
invented UI as a real screenshot or edit what a real screen says. The home hero's picture
shows emisar's own job: an agent's requests meeting your policy (allowed, waiting for a
person, refused) and the record they leave. Something an agent can do through emisar, such
as charting a metrics query, may appear lower on the page but never leads the hero: a
chart-led hero made emisar read as a Grafana replacement (2026-10-29). A mock of chat
bubbles and tool-call rows with verdict chips beside an approval card read as "generic AI
slop" that "doesn't sell the product" (2026-10-29): lead with the autonomy the agent gains,
let control make it believable, and give the hero one striking idea of its own. A
"production map" of glowing nodes, curved light paths, and a giant logo gate was "ultimate
ai slop ... ugly as fuck" (2026-10-29): no network graphs, glow-on-everything, or label
farms in the hero.

**Explainer diagrams.** An animated diagram (how it works, the request path) is one
self-contained component on the page, a sibling of the `emisar_demo` panel: the site's own
tokens (Inter, zinc cards, brand icon tiles, the `priv/icons` set, status pills), named
states that advance on their own with a visible stepper the reader can click, and a
complete still frame under reduced motion. It never binds to or hijacks scroll. Pace it for
reading: each state holds until its caption can be read (about 180 words a minute after its
motion ends). The caption is the most prominent text in the element, beside the drawing,
never a quiet footer line, with previous, pause, and next controls right next to it; manual
navigation stops auto-advance. A "before" state first shows what is wrong: each old path
actually working and its concrete danger (a secret printed in output and pasted into a chat,
a command an agent runs with nothing checking it), one state per path. Never foreshadow a
later step: no "No packs yet" text and no dashed placeholder slots; an element appears in the
step that introduces it, and its container grows as content lands. Make it
engaging through motion craft (light travelling a path, smooth state changes, a real
product fragment at the moment that matters), never through toy gimmicks: no animated
cursors, cartridges, shutters, or numbered balloons, and no wireframe look of thin boxes
and small type. Judge it inside the live page and beside professional product animation.

**Why.** The founder rejected two full rounds of ten pages. Round 1 (2026-10-16): "ALL
designs are super overloaded and not minimalistic making it super hard for user to read
and understand anything, ITS ALL AI SLOP!" Round 2 (2026-10-19): "first of all emisar is
dark themed, second in trying to make it simple you made it so generic and boring this
will not sell to anyone, and all 10 variants look the same... make them STUNNING,
slightly animated, outstanding and each unique!" Simplicity is in the reading, not in the
absence of design. A scroll-driven How it works schema (2026-10-28) was rejected as "too
silly and weak, not like result of work of a professional designer"; he asked for "self-
contained element that matches overall design, feel and aestetics of emisar website
(maybe transition automatically via states etc)".

**Review.** Judge full-page desktop and mobile screenshots. Five-second test: a stranger
can say what the product is and who it is for. Memory test: they can describe the page's
signature visual afterwards. Then remove clutter that serves neither test.
