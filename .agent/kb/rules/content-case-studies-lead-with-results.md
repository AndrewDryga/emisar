# Case studies lead with customer results

**Rule.** Case-study headlines, fact strips, and listing cards emphasize what
changed for the customer: error rate, response time, time to diagnose or deliver
a fix, downtime, cost, or operator effort. Connection limits, cache lifetimes,
and similar implementation settings belong in the explanation, not the headline
results. Use fewer facts when only a few useful outcomes are supported.
When the work produced the result, describe that delivery in the headline. Keep
the verification method in the body.

In guides and case studies, include an error or failure only when it explains the
problem, the chosen fix, or a material outcome. Omit incidental tool errors,
rejected query syntax, empty exploratory searches, and abandoned proposals when
the reader only needs the successful action and its finding. Keep essential
incident evidence and outcome limits; do not turn the guide into a work log.

Keep the stages in the order the work happened. Explain the starting state and
the transition before showing its outcome: staged applications, data replication,
traffic cutover, scaling, and retirement are distinct steps. Attach action results
to the phase they actually checked, and distinguish development from production.
Do not move a later ownership review into preparation or turn several cleanup
passes into one prerequisite that was never completed that way.
Preserving chronology does not require narrating every follow-up audit. Keep
ownership and state housekeeping only when it explains the main work or result.
Include the implementation that produced the state being checked. When the agent
read application code, adapted an existing environment, or wrote Terraform, say
so before describing the deployment or plan review. Concrete emisar checks should
support the account of that work, not replace it.

Each measured claim names a defensible boundary. A time to a tested image is not
time to production recovery. A before/after comparison needs observations from
both sides of the change; a quiet interval before deployment cannot stand in for
the after measurement. Preserve the relevant scope and measurement window in the
body, and do not invent numbers to fill a layout.
Keep agreed measurement definitions in the task evidence. Do not restore the
human-waiting note to the website cache-stampede report or its listing card;
the operator explicitly removed it.

Show how emisar advanced the investigation: the question, the action, the result,
and the next decision. Name the concrete action at the point of use; repeating
"through emisar" does not explain what the agent did or learned. A short list of
action names hides repeated checks, cross-service comparisons, and adaptations
to incomplete results. Keep earlier incident evidence separate from the final
repair and from post-deployment proof;
do not attribute direct shell or source work to emisar.

Describe the confirmed delivery path separately from inspection. A fix pushed to
an infrastructure repository and applied by the operator is not an SSH repair
by the agent. Do not carry a superseded local-only checkpoint into the account
of the completed delivery.

Describe operator decisions as the plan the team carried out. Do not frame the
story as an argument between the agent's recommendation and the operator's
choice, complain about approved decisions, or append cautionary commentary that
second-guesses them. State the implemented behavior and measured effects in
neutral terms. Keep factual limits needed to interpret the evidence, such as an
estimated cost or an unperformed restore test, without turning them into a
judgment of the operator. Operator feedback that corrected the agent's work can
still explain how the result improved.

Publish the contributing model names and versions, reasoning effort, harness
version, and local sandbox settings in a concise setup section. Verify these
against the original session record, distinguish each model's role when the
session switches models, and keep the agent's local permissions separate from
emisar's infrastructure controls. Do not infer an unrecorded version or snapshot.
Name the outer sandbox separately from the harness settings inside it: Codex's
`danger-full-access` mode can run inside co:op and does not establish unrestricted
host access. Link the named sandbox to its public site.
Do not infer direct infrastructure access from command syntax or a harness's
sandbox mode. Record the outer sandbox and access path the operator confirms.
Verify each named action against its contract; a read that checks a change must
not be described as performing the change.

**Why.** A buyer needs to understand the value of the work. Technical settings
explain how the fix works, but they do not show that it saved time, reduced
failures, or improved service.

**Example.** Prefer "Tested fix ready: 27 minutes" with the incident-to-CI
boundary explained nearby over "Connection limit: 1,000 per frontend" or
"Fresh cache: 2 hours."

**Sweep.** Apply this to the affected report and its hub card together. Review
other reports when their content is next edited; do not invent a mechanical
metric whitelist or turn a narrow correction into an unrelated content sweep.
