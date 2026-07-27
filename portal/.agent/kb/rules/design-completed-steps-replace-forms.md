# Completed workflow steps replace their forms

**Rule.** A successful form submission advances the workflow by replacing the edit form
with that step's completed result. Numbered workflows always render a contiguous visible
sequence: step 2 never appears unless step 1 is also visible in its current state.

## Why

Stacking a success result above a reset form presents two contradictory states at once:
the task looks both complete and ready to repeat. Showing a later step without the earlier
number also makes the page read as if content is missing. Mutually exclusive edit and
success branches preserve the operator's place and make the next action unambiguous.

## Good

```heex
<%= if @created_secret do %>
  <section id="save-step">
    <.step_header step={1} title="Save your key" />
    <.code_panel code={@created_secret} />
  </section>
<% else %>
  <section id="create-step">
    <.step_header step={1} title="Create a key" />
    <.simple_form for={@form}>...</.simple_form>
  </section>
<% end %>

<section :if={@created_secret} id="connect-step">
  <.step_header step={2} title="Connect your agent" />
</section>
```

## Bad

```heex
<.code_panel :if={@created_secret} code={@created_secret} />
<.simple_form for={@form}>...</.simple_form>

<section :if={@created_secret}>
  <.step_header step={2} title="Connect your agent" />
</section>
```

The reset form remains actionable after success, and step 2 has no visible step 1.

## Sweep

Search LiveViews for success assigns rendered in the same branch as their source
`<.simple_form>`, then inspect every conditional `step={2}` or later header across all
reachable states. Edit and completed branches should be mutually exclusive.

## Enforcement

This is a workflow judgment rule, not a Credo check. LiveView tests assert the form branch
before submission and the completed-result branch plus contiguous next step afterward.
