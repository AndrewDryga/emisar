defmodule Emisar.Repo.Migrations.RenameAgentsToRunners do
  use Ecto.Migration

  @moduledoc """
  Rebrand: "agent" → "runner" everywhere it refers to our process
  running on a managed host. "Agent" was overloaded in the LLM world
  (an LLM agent is the *caller*, not the *executor*). After this
  migration there is no ambiguity: the LLM agent calls into emisar's
  runners.

  Renames preserve all data, keys, indexes, and foreign-key targets.
  The HTTP `User-Agent` header column on audit_events is untouched.
  """

  def up do
    rename(table(:agents), to: table(:runners))
    rename(table(:agent_auth_keys), to: table(:runner_auth_keys))
    rename(table(:agent_tokens), to: table(:runner_tokens))
    rename(table(:agent_actions), to: table(:runner_actions))
    rename(table(:agent_event_cursors), to: table(:runner_event_cursors))

    rename(table(:runners), :agent_version, to: :runner_version)

    rename(table(:runner_tokens), :agent_id, to: :runner_id)
    rename(table(:runner_actions), :agent_id, to: :runner_id)
    rename(table(:runner_event_cursors), :agent_id, to: :runner_id)
    rename(table(:action_runs), :agent_id, to: :runner_id)

    rename(table(:api_keys), :agent_filter, to: :runner_filter)
  end

  def down do
    rename(table(:api_keys), :runner_filter, to: :agent_filter)

    rename(table(:action_runs), :runner_id, to: :agent_id)
    rename(table(:runner_event_cursors), :runner_id, to: :agent_id)
    rename(table(:runner_actions), :runner_id, to: :agent_id)
    rename(table(:runner_tokens), :runner_id, to: :agent_id)

    rename(table(:runners), :runner_version, to: :agent_version)

    rename(table(:runner_event_cursors), to: table(:agent_event_cursors))
    rename(table(:runner_actions), to: table(:agent_actions))
    rename(table(:runner_tokens), to: table(:agent_tokens))
    rename(table(:runner_auth_keys), to: table(:agent_auth_keys))
    rename(table(:runners), to: table(:agents))
  end
end
