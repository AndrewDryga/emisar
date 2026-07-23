# Rule: durable knowledge has an explicit audience

**Rule.** Knowledge under `.agent/kb/` and `.agent/kb/rules/` is customer-safe and
public by default. Company working material that should not feed a customer-facing
surface belongs under the gitignored `.agent/kb/internal/` subtree. Internal
material is reviewed for the exact destination before publication; the approved
result moves to the public source instead of making that source depend on an
internal file. Neither area stores secrets or private customer data.

**Why.** Mixing campaign drafts, private operating context, and approved product
facts makes it too easy for an agent to quote an unreviewed claim or expose a
working document through customer documentation. A visible directory boundary
keeps public knowledge reusable while preserving useful internal context.

**Good.** Draft campaign creative lives under `kb/internal/marketing/`; an approved
product fact is written into a public descriptive card or the customer-facing
document that owns it.

**Bad.** A public guide links into `kb/internal/`, a customer skill treats an
internal launch plan as product truth, or credentials are committed because the
directory is named `internal`.

**Sweep.** Search public docs, website templates, public skills, and product copy
for `.agent/kb/internal` references before shipping. When adding durable marketing
or company-only material, search outside `internal/` for private drafts that should
move behind the audience boundary.

**Enforced.** Review plus `dev/run check agent-setup`; Git ignores `internal/`, and
the knowledge-card audit treats it as a separate material store rather than a
public descriptive-card namespace.
