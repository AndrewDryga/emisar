defmodule Emisar.Policies do
  @moduledoc """
  Policy CRUD + evaluation. Cloud evaluates policy *before* sending
  `run_action`; if the decision is `allow`, the run goes to the
  transport. If `require_approval`, it goes to the approval queue.
  If `deny`, the run is short-circuited and the caller sees a
  policy_denied error.
  """

  import Ecto.Query
  alias Emisar.Repo
  alias Emisar.Policies.Policy

  # -- CRUD -------------------------------------------------------------

  def list_policies(account_id) do
    from(p in Policy,
      where: p.account_id == ^account_id and is_nil(p.archived_at),
      order_by: [desc: p.is_default, asc: p.name, desc: p.version]
    )
    |> Repo.all()
  end

  def get_policy(account_id, id) do
    from(p in Policy, where: p.account_id == ^account_id and p.id == ^id)
    |> Repo.one()
  end

  def get_default_policy(account_id) do
    from(p in Policy,
      where: p.account_id == ^account_id and p.is_default and is_nil(p.archived_at),
      order_by: [desc: p.version],
      limit: 1
    )
    |> Repo.one()
  end

  def create_policy(account_id, attrs, user_id) do
    %Policy{}
    |> Policy.changeset(
      Map.merge(attrs, %{
        account_id: account_id,
        created_by_id: user_id,
        version: 1
      })
    )
    |> Repo.insert()
  end

  def save_new_version(%Policy{} = old, attrs, user_id) do
    attrs =
      Map.merge(
        %{
          account_id: old.account_id,
          name: old.name,
          description: old.description,
          version: old.version + 1,
          is_default: old.is_default,
          created_by_id: user_id
        },
        attrs
      )

    %Policy{} |> Policy.changeset(attrs) |> Repo.insert()
  end

  def archive_policy(%Policy{} = policy) do
    policy
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> Repo.update()
  end

  # -- Evaluation -------------------------------------------------------

  @doc """
  Evaluate a policy for a candidate action call.

  Returns `{decision, matched_rules, reason}` where decision is one of
  `:allow`, `:require_approval`, `:deny`.
  """
  def evaluate(%Policy{} = policy, %{} = subject, %{} = args) do
    rules = policy.rules || %{}
    deny_hit = match_first(rules["deny"] || [], subject, args)
    approval_hits = match_all(rules["require_approval"] || [], subject, args)
    allow_hits = match_all(rules["allow"] || [], subject, args)

    cond do
      deny_hit != nil ->
        {:deny, [rule_name(deny_hit)], "matched deny rule #{rule_name(deny_hit)}"}

      approval_hits != [] ->
        {:require_approval, Enum.map(approval_hits, &rule_name/1), "requires approval"}

      allow_hits != [] ->
        {:allow, Enum.map(allow_hits, &rule_name/1), "matched allow rule"}

      true ->
        {:deny, [], "no matching allow rule"}
    end
  end

  # Default-deny when no policy exists. Workspaces always get a seeded
  # default policy on creation; if a workspace somehow has zero
  # policies, refuse to dispatch rather than silently allowing.
  def evaluate(nil, _subject, _args),
    do: {:deny, [], "no policy configured for this account"}

  @doc """
  Account-scoped convenience that looks up the default policy and
  extracts subject metadata from the dispatch attrs.
  """
  def evaluate(account_id, attrs) when is_binary(account_id) do
    policy = get_default_policy(account_id)

    subject = %{
      "action_id" => attrs[:action_id] || attrs["action_id"],
      "risk" => attrs[:risk] || attrs["risk"] || "low",
      "kind" => attrs[:kind] || attrs["kind"] || "exec"
    }

    args = attrs[:args] || attrs["args"] || %{}
    evaluate(policy, subject, args)
  end

  @doc """
  Same as `evaluate/2`, but additionally returns the policy struct that
  produced the decision so callers can attach `policy_id` and
  `policy_version` to the run. Returns
  `{decision, matched_rules, reason, policy_or_nil}`.
  """
  def evaluate_with_policy(account_id, attrs) when is_binary(account_id) do
    policy = get_default_policy(account_id)

    subject = %{
      "action_id" => attrs[:action_id] || attrs["action_id"],
      "risk" => attrs[:risk] || attrs["risk"] || "low",
      "kind" => attrs[:kind] || attrs["kind"] || "exec"
    }

    args = attrs[:args] || attrs["args"] || %{}
    {decision, matched, reason} = evaluate(policy, subject, args)
    {decision, matched, reason, policy}
  end

  defp match_first(rules, subject, args) do
    Enum.find(rules, &match_rule?(&1, subject, args))
  end

  defp match_all(rules, subject, args) do
    Enum.filter(rules, &match_rule?(&1, subject, args))
  end

  defp match_rule?(rule, subject, args) do
    matches_action_glob?(rule, subject) and
      matches_risk?(rule, subject) and
      matches_kind?(rule, subject) and
      matches_args?(rule, args)
  end

  defp matches_action_glob?(%{"action" => pattern}, %{"action_id" => id})
       when is_binary(pattern) and is_binary(id),
       do: glob_match?(pattern, id)

  defp matches_action_glob?(_, _), do: true

  defp matches_risk?(%{"max_risk" => max}, %{"risk" => actual})
       when is_binary(max) and is_binary(actual),
       do: risk_rank(actual) <= risk_rank(max)

  defp matches_risk?(%{"risk" => required}, %{"risk" => actual})
       when is_binary(required) and is_binary(actual),
       do: required == actual

  defp matches_risk?(_, _), do: true

  defp matches_kind?(%{"kind" => required}, %{"kind" => actual})
       when is_binary(required) and is_binary(actual),
       do: required == actual

  defp matches_kind?(_, _), do: true

  defp matches_args?(%{"args" => conditions}, args) when is_map(conditions) do
    Enum.all?(conditions, fn {name, cond} -> arg_matches?(cond, Map.get(args, name)) end)
  end

  defp matches_args?(_, _), do: true

  defp arg_matches?(%{"equals" => want}, got), do: want == got
  defp arg_matches?(%{"in" => list}, got) when is_list(list), do: got in list
  defp arg_matches?(_, _), do: true

  defp risk_rank("low"), do: 0
  defp risk_rank("medium"), do: 1
  defp risk_rank("high"), do: 2
  defp risk_rank("critical"), do: 3
  defp risk_rank(_), do: 4

  defp rule_name(%{"name" => name}) when is_binary(name), do: name
  defp rule_name(_), do: "unnamed"

  defp glob_match?(pattern, str) do
    if String.contains?(pattern, "*") do
      escaped = pattern |> Regex.escape() |> String.replace("\\*", ".*")
      regex = Regex.compile!("^" <> escaped <> "$")
      Regex.match?(regex, str)
    else
      pattern == str
    end
  end
end
