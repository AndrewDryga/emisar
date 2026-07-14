defmodule Emisar.Catalog.MCPProjection do
  @moduledoc """
  Pure projection of trusted pack manifests onto current runner deployments.

  Runner advertisements are deployment evidence only. Model-facing action
  descriptors always come from an exact-hash trusted manifest, and a runner is
  compatible only when its complete advertised descriptor matches that
  manifest.
  """
  alias Emisar.Catalog.{PackBaseline, PackVersion, RunnerAction, TrustedManifest}
  alias Emisar.{Crypto, Runners}

  @pack_id_format ~r/\A[a-z][a-z0-9_-]*\z/
  @pack_version_format ~r/\A[0-9]+(?:\.[0-9]+)*\z/
  @pack_hash_format ~r/\Asha256:[0-9a-f]{64}\z/
  @runner_name_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/
  @unsafe_text ~r/[\p{Cc}\p{Cf}\p{Cs}]/u
  @max_external_id_bytes 256
  @max_labels 32
  @max_label_key_length 80
  @max_label_value_length 256

  @doc "Build a deterministic trusted catalog snapshot from already-authorized rows."
  @spec build([PackVersion.t()], [RunnerAction.t()], [Runners.Runner.t()]) :: map()
  def build(pack_versions, runner_actions, runners)
      when is_list(pack_versions) and is_list(runner_actions) and is_list(runners) do
    projected_runners =
      runners |> Enum.flat_map(&project_runner/1) |> Enum.sort_by(& &1.runner_ref)

    runners_by_id = Map.new(projected_runners, &{&1.id, &1})

    actions_by_deployment =
      runner_actions
      |> Enum.filter(&Map.has_key?(runners_by_id, &1.runner_id))
      |> Enum.group_by(&{&1.runner_id, &1.pack_id, &1.pack_version, &1.pack_hash})

    pack_versions_by_id = Map.new(pack_versions, &{{&1.pack_id, &1.version}, &1})

    deployments =
      projected_runners
      |> Enum.flat_map(&runner_deployments/1)
      |> Enum.group_by(& &1.pack_ref)

    skewed_pack_ids =
      deployments
      |> Map.keys()
      |> Enum.group_by(&pack_id_from_ref/1)
      |> Enum.filter(fn {_pack_id, refs} -> length(refs) > 1 end)
      |> Enum.map(fn {pack_id, _refs} -> pack_id end)
      |> MapSet.new()

    packs =
      deployments
      |> Enum.map(fn {_pack_ref, pack_deployments} ->
        build_pack(
          pack_deployments,
          pack_versions_by_id,
          actions_by_deployment,
          skewed_pack_ids
        )
      end)
      |> Enum.sort_by(& &1.pack_ref)

    pack_issues_by_runner = pack_issues_by_runner(packs)

    projected_runners =
      Enum.map(projected_runners, fn runner ->
        issues =
          (runner.issues ++ Map.get(pack_issues_by_runner, runner.id, []))
          |> unique_issues()

        %{runner | issues: issues}
      end)

    %{packs: packs, runners: projected_runners}
  end

  @doc "Stable readable runner reference derived from the durable runner external id."
  @spec runner_ref(Runners.Runner.t()) :: {:ok, String.t()} | {:error, :invalid_runner}
  def runner_ref(%Runners.Runner{name: name, external_id: external_id}) do
    with true <- valid_runner_name?(name),
         true <- valid_external_id?(external_id) do
      digest = external_id |> Crypto.hash_hex() |> binary_part(0, 32)
      {:ok, name <> "~" <> digest}
    else
      _ -> {:error, :invalid_runner}
    end
  end

  @doc "Canonical exact pack reference, or an error for an unrepresentable advertisement."
  @spec pack_ref(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_pack_ref}
  def pack_ref(pack_id, version, hash) do
    with true <- is_binary(pack_id) and Regex.match?(@pack_id_format, pack_id),
         true <- is_binary(version) and Regex.match?(@pack_version_format, version),
         true <- is_binary(hash) and Regex.match?(@pack_hash_format, hash) do
      {:ok, pack_id <> "@" <> version <> "/" <> hash}
    else
      _ -> {:error, :invalid_pack_ref}
    end
  end

  @doc "Parse a canonical pack reference into `{pack_id, version, hash}`."
  @spec parse_pack_ref(String.t()) ::
          {:ok, {String.t(), String.t(), String.t()}} | {:error, :invalid_pack_ref}
  def parse_pack_ref(pack_ref) when is_binary(pack_ref) do
    with [identity, hash] <- String.split(pack_ref, "/", parts: 2),
         [pack_id, version] <- String.split(identity, "@", parts: 2),
         {:ok, ^pack_ref} <- pack_ref(pack_id, version, hash) do
      {:ok, {pack_id, version, hash}}
    else
      _ -> {:error, :invalid_pack_ref}
    end
  end

  def parse_pack_ref(_pack_ref), do: {:error, :invalid_pack_ref}

  defp project_runner(%Runners.Runner{} = runner) do
    with {:ok, runner_ref} <- runner_ref(runner),
         true <- safe_text?(runner.hostname, 1, 255),
         true <- safe_text?(runner.group, 1, 80) do
      {labels, labels_valid?} = safe_labels(runner.labels)

      issues =
        [connection_issue(runner), metadata_issue(labels_valid?)]
        |> Enum.reject(&is_nil/1)

      [
        %{
          id: runner.id,
          runner_ref: runner_ref,
          name: runner.name,
          hostname: runner.hostname,
          group: runner.group,
          enforce_signatures: runner.enforce_signatures,
          status: runner_status(runner),
          last_seen_at: last_seen_at(runner),
          labels: labels,
          packs: runner.packs || %{},
          issues: issues
        }
      ]
    else
      _ -> []
    end
  end

  defp project_runner(_runner), do: []

  defp runner_deployments(runner) do
    Enum.flat_map(runner.packs, fn
      {pack_id, %{"version" => version, "hash" => hash}} ->
        case pack_ref(pack_id, version, hash) do
          {:ok, pack_ref} ->
            [
              %{
                pack_ref: pack_ref,
                pack_id: pack_id,
                version: version,
                hash: hash,
                runner_id: runner.id,
                runner_ref: runner.runner_ref,
                runner_status: runner.status
              }
            ]

          {:error, :invalid_pack_ref} ->
            []
        end

      _invalid ->
        []
    end)
  end

  defp build_pack(
         [%{pack_id: pack_id, version: version, hash: hash} | _] = deployments,
         pack_versions_by_id,
         actions_by_deployment,
         skewed_pack_ids
       ) do
    pack_version = Map.get(pack_versions_by_id, {pack_id, version})

    {trusted_actions, executable_trust?, trust_issue} =
      trusted_actions(pack_version, hash)

    compatibility =
      Map.new(deployments, fn deployment ->
        rows =
          Map.get(
            actions_by_deployment,
            {deployment.runner_id, pack_id, version, hash},
            []
          )

        {deployment.runner_id,
         deployment_compatibility(
           deployment,
           rows,
           trusted_actions,
           executable_trust?,
           trust_issue
         )}
      end)

    actions =
      trusted_actions
      |> Enum.map(fn {action_id, descriptor} ->
        compatible_runner_ids =
          compatibility
          |> Enum.filter(fn {_runner_id, result} -> action_id in result.compatible_action_ids end)
          |> Enum.map(fn {runner_id, _result} -> runner_id end)
          |> Enum.sort()

        descriptor
        |> Map.put("action_id", action_id)
        |> Map.put(:compatible_runner_ids, compatible_runner_ids)
      end)
      |> Enum.sort_by(& &1["action_id"])

    executable? = Enum.any?(actions, &(&1.compatible_runner_ids != []))

    issues =
      [
        trust_issue,
        descriptor_mismatch_issue(compatibility),
        no_connected_runner_issue(executable_trust?, executable?),
        partially_deployed_issue(executable?, compatibility),
        version_skew_issue(pack_id, skewed_pack_ids)
      ]
      |> Enum.reject(&is_nil/1)
      |> unique_issues()

    %{
      pack_ref: hd(deployments).pack_ref,
      pack_id: pack_id,
      version: version,
      hash: hash,
      availability: if(executable?, do: "executable", else: "unavailable"),
      issues: issues,
      actions: actions,
      compatibility: compatibility
    }
  end

  defp trusted_actions(
         %PackVersion{
           trust_state: :trusted,
           hash: hash,
           retirement_overridden_at: retirement_overridden_at,
           trusted_manifest: manifest,
           pack_id: pack_id,
           version: version
         },
         hash
       ) do
    case TrustedManifest.actions(manifest) do
      {:ok, actions} ->
        retired? = PackBaseline.retired?(pack_id, version) and is_nil(retirement_overridden_at)

        if retired? do
          {actions, false,
           issue("pack_retired", "This exact pack version is retired and cannot execute.")}
        else
          {actions, true, nil}
        end

      {:error, :incomplete_manifest} ->
        {%{}, false,
         issue("pack_untrusted", "This pack has no complete trusted action manifest.")}
    end
  end

  defp trusted_actions(%PackVersion{trust_state: :rejected}, _hash) do
    {%{}, false, issue("pack_rejected", "An operator rejected this exact pack version.")}
  end

  defp trusted_actions(%PackVersion{}, _hash) do
    {%{}, false, issue("pack_untrusted", "This exact pack version is awaiting trust review.")}
  end

  defp trusted_actions(nil, _hash) do
    {%{}, false, issue("pack_untrusted", "This exact pack version has no trust decision.")}
  end

  defp deployment_compatibility(
         deployment,
         rows,
         trusted_actions,
         executable_trust?,
         trust_issue
       ) do
    expected_action_ids = trusted_actions |> Map.keys() |> MapSet.new()

    matching_action_ids =
      rows
      |> Enum.filter(fn row ->
        case Map.fetch(trusted_actions, row.action_id) do
          {:ok, descriptor} -> runner_descriptor(row) == descriptor
          :error -> false
        end
      end)
      |> Enum.map(& &1.action_id)
      |> MapSet.new()

    advertised_action_ids = rows |> Enum.map(& &1.action_id) |> MapSet.new()

    descriptor_match? =
      expected_action_ids == matching_action_ids and
        advertised_action_ids == expected_action_ids

    compatible_action_ids =
      if executable_trust? and descriptor_match? and deployment.runner_status == "connected" do
        matching_action_ids |> MapSet.to_list() |> Enum.sort()
      else
        []
      end

    issues =
      [
        trust_issue,
        if(descriptor_match?,
          do: nil,
          else:
            issue(
              "descriptor_mismatch",
              "The runner advertisement does not match the complete trusted manifest."
            )
        )
      ]
      |> Enum.reject(&is_nil/1)

    %{
      runner_ref: deployment.runner_ref,
      status: deployment.runner_status,
      descriptor_match?: descriptor_match?,
      compatible_action_ids: compatible_action_ids,
      issues: issues
    }
  end

  defp runner_descriptor(%RunnerAction{} = action) do
    %{
      "title" => action.title,
      "summary" => action.summary || summary(action.description),
      "description" => action.description,
      "kind" => to_string(action.kind),
      "risk" => to_string(action.risk),
      "side_effects" => action.side_effects || [],
      "args_schema" => action.args_schema || %{},
      "examples" => action.examples || [],
      "search_terms" => action.search_terms || []
    }
  end

  defp summary(description) when is_binary(description) do
    description
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, 512)
  end

  defp summary(_description), do: nil

  defp pack_issues_by_runner(packs) do
    Enum.reduce(packs, %{}, fn pack, issues_by_runner ->
      Enum.reduce(pack.compatibility, issues_by_runner, fn {runner_id, compatibility}, acc ->
        Map.update(acc, runner_id, compatibility.issues, &(&1 ++ compatibility.issues))
      end)
    end)
  end

  defp descriptor_mismatch_issue(compatibility) do
    if Enum.any?(compatibility, fn {_runner_id, result} -> not result.descriptor_match? end) do
      issue(
        "descriptor_mismatch",
        "At least one runner advertisement differs from the complete trusted manifest."
      )
    end
  end

  defp no_connected_runner_issue(true, false) do
    issue("no_connected_runner", "No connected compatible runner can execute this pack.")
  end

  defp no_connected_runner_issue(_trusted?, _executable?), do: nil

  defp partially_deployed_issue(true, compatibility) do
    if Enum.any?(compatibility, fn {_runner_id, result} ->
         result.status != "connected" or not result.descriptor_match?
       end) do
      issue(
        "partially_deployed",
        "Only part of the observed deployment is connected and manifest-compatible."
      )
    end
  end

  defp partially_deployed_issue(_executable?, _compatibility), do: nil

  defp version_skew_issue(pack_id, skewed_pack_ids) do
    if MapSet.member?(skewed_pack_ids, pack_id) do
      issue("version_skew", "In-scope runners advertise more than one exact ref for this pack.")
    end
  end

  defp connection_issue(%Runners.Runner{} = runner) do
    case runner_status(runner) do
      "connected" -> nil
      "disconnected" -> issue("runner_disconnected", "The runner is disconnected.")
      "pending" -> issue("runner_pending", "The runner has not connected yet.")
      "disabled" -> issue("runner_disabled", "The runner is disabled.")
    end
  end

  defp metadata_issue(true), do: nil

  defp metadata_issue(false) do
    issue("runner_metadata_invalid", "Some runner labels were omitted because they were invalid.")
  end

  defp safe_labels(labels) when is_map(labels) do
    valid =
      labels
      |> Enum.filter(fn {key, value} ->
        safe_text?(key, 1, @max_label_key_length) and
          safe_text?(value, 0, @max_label_value_length)
      end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.take(@max_labels)

    {Map.new(valid), length(valid) == map_size(labels)}
  end

  defp safe_labels(_labels), do: {%{}, false}

  defp safe_text?(value, min, max) when is_binary(value) do
    String.valid?(value) and String.length(value) in min..max and
      not Regex.match?(@unsafe_text, value)
  end

  defp safe_text?(_value, _min, _max), do: false

  defp valid_runner_name?(name),
    do: is_binary(name) and Regex.match?(@runner_name_format, name)

  defp valid_external_id?(external_id) do
    is_binary(external_id) and byte_size(external_id) in 1..@max_external_id_bytes
  end

  defp runner_status(%Runners.Runner{disabled_at: %DateTime{}}), do: "disabled"
  defp runner_status(%Runners.Runner{online?: true}), do: "connected"
  defp runner_status(%Runners.Runner{last_connected_at: nil}), do: "pending"
  defp runner_status(%Runners.Runner{}), do: "disconnected"

  defp last_seen_at(%Runners.Runner{} = runner) do
    runner.last_heartbeat_at || runner.last_disconnected_at || runner.last_connected_at
  end

  defp pack_id_from_ref(pack_ref) do
    {:ok, {pack_id, _version, _hash}} = parse_pack_ref(pack_ref)
    pack_id
  end

  defp issue(code, message), do: %{code: code, message: message}

  defp unique_issues(issues) do
    issues
    |> Enum.uniq_by(& &1.code)
    |> Enum.sort_by(& &1.code)
  end
end
