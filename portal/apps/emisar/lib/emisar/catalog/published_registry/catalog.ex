defmodule Emisar.Catalog.PublishedRegistry.Catalog do
  @moduledoc """
  Parses and validates a published `catalog.json` document into
  `Emisar.Catalog.PublishedRegistry.Pack` structs plus the trust snapshot
  `Emisar.Catalog.PackBaseline` judges runner advertisements against.

  The catalog is produced out-of-band by `packctl catalog build`
  (the runner's loader is the single source of the content hash, so the
  portal, the runner, and the catalog agree byte-for-byte). This module
  is the portal's trust boundary for that artifact: it is a public,
  attacker-influenceable document served to every `emisar pack install`,
  so a malformed or hostile catalog must be **rejected**, never partially
  loaded. Validation covers the schema version, required fields, unique
  pack and action ids, the `sha256:…` hash shape, safe HTTPS URLs (a
  cleartext or `javascript:` link would ride into a rendered `href` or
  the tarball redirect), the exec-command template shape, and — through
  `Emisar.Catalog.TrustedManifest`, the one owner of that contract — that
  every action is a complete trusted descriptor, so the declared `args`
  the command preview renders and masks by are as trustworthy as the
  template itself. The trust snapshot adds the checks that used to run at
  build time: every version — current, retained history, and retirement
  watermark — is SemVer, each `(pack_id, version)` appears exactly once,
  and the current version's actions build a complete manifest. Those now
  fail the *document* at refresh, so a bad publish holds the last-good
  catalog instead of taking the portal down.

  Pure — no Repo, no HTTP, no side effects. The cache
  (`Emisar.Catalog.PublishedRegistry.Cache`) owns fetching and last-good
  caching.
  """

  alias Emisar.Catalog.PublishedRegistry.{Action, Pack}
  alias Emisar.Catalog.TrustedManifest

  @schema_version 1
  @max_generation 9_007_199_254_740_991
  @hash_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @risks ~w(low medium high critical)
  @kinds ~w(exec script)

  @typedoc """
  What the published catalog says we publish: the canonical hash of every
  `(pack_id, version)` in the trust window, the complete manifest for each
  exact `(pack_id, version, hash)` the catalog still carries actions for, the
  retirement watermarks, and each pack's current version.
  """
  @type trust :: %{
          baseline: %{{String.t(), String.t()} => String.t()},
          manifests: %{{String.t(), String.t(), String.t()} => map()},
          retired_below: %{String.t() => String.t()},
          current_versions: %{String.t() => String.t()}
        }

  @doc """
  Decode + validate a catalog (a JSON string or an already-decoded map) into
  the full pack list, alphabetically by id, and the trust snapshot.

  `{:ok, %{packs: packs, trust: trust}}` on success; `{:error, message}` — a
  human-readable reason for the operational log — on any malformation.

  Trust is built from the SAME decoded document in one pass rather than from
  the returned structs: `Pack.previous_versions` carries no actions, so a
  manifest map derived from it would silently drop every historical
  descriptor.
  """
  @spec parse(binary() | map()) ::
          {:ok, %{generation: non_neg_integer(), packs: [Pack.t()], trust: trust()}}
          | {:error, String.t()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> parse(data)
      {:error, _} -> {:error, "catalog is not valid JSON"}
    end
  end

  def parse(%{"schema_version" => @schema_version, "packs" => packs} = catalog)
      when is_list(packs) do
    with {:ok, generation} <- fetch_generation(catalog),
         {:ok, parsed} <- parse_packs(packs),
         {:ok, trust} <- parse_trust(packs) do
      {:ok, %{generation: generation, packs: Enum.sort_by(parsed, & &1.id), trust: trust}}
    end
  end

  def parse(%{"schema_version" => version}) do
    {:error, "unsupported catalog schema_version #{inspect(version)} (want #{@schema_version})"}
  end

  def parse(_data), do: {:error, "catalog missing schema_version or packs"}

  defp fetch_generation(%{"generation" => generation})
       when is_integer(generation) and generation > 0 and generation <= @max_generation,
       do: {:ok, generation}

  defp fetch_generation(%{"generation" => _generation}),
    do: {:error, "catalog generation must be an integer between 1 and #{@max_generation}"}

  defp fetch_generation(_catalog), do: {:error, "catalog missing generation"}

  defp parse_packs(packs) do
    acc = {[], MapSet.new(), MapSet.new()}

    result =
      Enum.reduce_while(packs, {:ok, acc}, fn raw, {:ok, {out, pack_ids, action_ids}} ->
        with {:ok, pack} <- parse_pack(raw),
             {:ok, pack_ids} <-
               put_unique(pack_ids, pack.id, "duplicate pack id #{inspect(pack.id)}"),
             {:ok, action_ids} <- put_action_ids(action_ids, pack) do
          {:cont, {:ok, {[pack | out], pack_ids, action_ids}}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, {out, _pack_ids, _action_ids}} <- result, do: {:ok, out}
  end

  # Runs over the raw entries `parse_packs/1` has already proved structurally
  # sound, so every read below is against a validated shape.
  defp parse_trust(packs) do
    empty = %{baseline: %{}, manifests: %{}, retired_below: %{}, current_versions: %{}}

    Enum.reduce_while(packs, {:ok, empty}, fn raw, {:ok, trust} ->
      case put_pack_trust(trust, raw) do
        {:ok, trust} -> {:cont, {:ok, trust}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The current entry lands first so the history reduce can see it: a previous
  # version repeating the current one is the same collision as two equal
  # previous versions, and both are rejected there.
  defp put_pack_trust(trust, %{"id" => id, "version" => version, "content_hash" => hash} = raw) do
    watermark = raw["retired_below"]

    with :ok <- validate_version(id, version),
         :ok <- validate_watermark(id, watermark),
         {:ok, manifest} <- current_manifest(id, version, raw["actions"]) do
      trust = %{
        trust
        | baseline: Map.put(trust.baseline, {id, version}, hash),
          manifests: Map.put(trust.manifests, {id, version, hash}, manifest),
          retired_below: put_watermark(trust.retired_below, id, watermark),
          current_versions: Map.put(trust.current_versions, id, version)
      }

      put_previous_trust(trust, id, raw["previous_versions"] || [])
    end
  end

  defp put_previous_trust(trust, pack_id, previous_versions) do
    Enum.reduce_while(previous_versions, {:ok, trust}, fn previous, {:ok, trust} ->
      case put_previous_version(trust, pack_id, previous) do
        {:ok, trust} -> {:cont, {:ok, trust}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A retained previous version always carries its baseline hash, so a runner
  # on a slightly-older shipped version still auto-pins. Its complete manifest
  # rides along only when the catalog still holds that version's actions —
  # history published before descriptor retention has none, and that means "no
  # retained descriptors", not a bad document.
  defp put_previous_version(
         trust,
         pack_id,
         %{"version" => version, "content_hash" => hash} = previous
       ) do
    with :ok <- validate_version(pack_id, version),
         :ok <- ensure_unique_version(trust, pack_id, version) do
      {:ok,
       %{
         trust
         | baseline: Map.put(trust.baseline, {pack_id, version}, hash),
           manifests:
             put_previous_manifest(trust.manifests, {pack_id, version, hash}, previous["actions"])
       }}
    end
  end

  # Two entries for one `(pack_id, version)` would silently overwrite each
  # other, so which bytes auto-trust that version would depend on document
  # order — reject the publish instead of picking a winner.
  defp ensure_unique_version(trust, pack_id, version) do
    if Map.has_key?(trust.baseline, {pack_id, version}),
      do: {:error, "pack #{inspect(pack_id)} lists version #{inspect(version)} more than once"},
      else: :ok
  end

  defp put_previous_manifest(manifests, _key, nil), do: manifests

  defp put_previous_manifest(manifests, key, actions) do
    case TrustedManifest.from_catalog_actions(actions) do
      {:ok, manifest} -> Map.put(manifests, key, manifest)
      {:error, :invalid_manifest} -> manifests
    end
  end

  # The current version's descriptors ARE what auto-trust pins, so an invalid
  # manifest rejects the whole document — half a trusted pack would authorize
  # and describe bytes we can't stand behind.
  defp current_manifest(pack_id, version, actions) do
    case TrustedManifest.from_catalog_actions(actions) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :invalid_manifest} ->
        {:error, "pack #{inspect(pack_id)} version #{version} has an invalid action manifest"}
    end
  end

  defp put_watermark(watermarks, _pack_id, nil), do: watermarks
  defp put_watermark(watermarks, pack_id, watermark), do: Map.put(watermarks, pack_id, watermark)

  # Every version the catalog publishes must be SemVer, because the
  # dispatch-time retirement compare relies on it. Junk fails the document at
  # refresh — the cache holds its last-good copy — never a dispatch gate.
  defp validate_version(pack_id, version) do
    case Version.parse(version) do
      {:ok, _parsed} ->
        :ok

      :error ->
        {:error, "pack #{inspect(pack_id)} has an unparseable version #{inspect(version)}"}
    end
  end

  defp validate_watermark(_pack_id, nil), do: :ok

  defp validate_watermark(pack_id, watermark) do
    case Version.parse(watermark) do
      {:ok, _parsed} ->
        :ok

      :error ->
        {:error,
         "pack #{inspect(pack_id)} has an unparseable retired_below #{inspect(watermark)}"}
    end
  end

  defp parse_pack(%{} = raw) do
    with {:ok, id} <- fetch_string(raw, "id"),
         {:ok, name} <- fetch_string(raw, "name"),
         {:ok, version} <- fetch_string(raw, "version"),
         {:ok, vendor} <- fetch_string(raw, "vendor"),
         {:ok, source_url} <- fetch_url(raw, "source_url", id),
         {:ok, homepage} <- fetch_url(raw, "homepage", id),
         {:ok, tarball_url} <- fetch_url(raw, "tarball_url", id),
         {:ok, content_hash} <- fetch_hash(raw, id),
         {:ok, previous_versions} <- fetch_previous_versions(raw, id),
         {:ok, retired_below} <- fetch_retired_below(raw, id),
         {:ok, requires_os, requires_binaries} <- fetch_requires(raw, id),
         {:ok, detect} <- fetch_detect(raw, id),
         {:ok, setup} <- fetch_setup(raw, id),
         {:ok, actions} <- fetch_actions(raw, id),
         :ok <- validate_host_access_actions(setup, actions, id) do
      {:ok,
       %Pack{
         id: id,
         name: name,
         version: version,
         description: string_field(raw, "description"),
         vendor: vendor,
         homepage: homepage,
         source_url: source_url,
         requires_os: requires_os,
         requires_binaries: requires_binaries,
         content_hash: content_hash,
         tarball_url: tarball_url,
         previous_versions: previous_versions,
         retired_below: retired_below,
         detect: detect,
         setup: setup,
         actions: actions
       }}
    end
  end

  defp parse_pack(_raw), do: {:error, "catalog pack entry is not an object"}

  defp fetch_actions(raw, pack_id) do
    case Map.get(raw, "actions") do
      actions when is_list(actions) ->
        reduce_ok(actions, &parse_action(&1, pack_id))

      _ ->
        {:error, "pack #{inspect(pack_id)} is missing an actions list"}
    end
  end

  defp parse_action(%{} = raw, pack_id) do
    with {:ok, id} <- fetch_string(raw, "id"),
         {:ok, title} <- fetch_string(raw, "title"),
         {:ok, kind} <- fetch_enum(raw, "kind", @kinds, pack_id),
         {:ok, risk} <- fetch_enum(raw, "risk", @risks, pack_id),
         {:ok, command} <- fetch_command(raw, id),
         {:ok, args} <- fetch_args(raw, id) do
      action = %Action{
        id: id,
        title: title,
        kind: kind,
        risk: risk,
        command: command,
        args: args,
        description: string_field(raw, "description")
      }

      {:ok, action}
    end
  end

  defp parse_action(_raw, pack_id),
    do: {:error, "pack #{inspect(pack_id)} has an action entry that is not an object"}

  # A command is optional (script-kind actions carry none); when present it
  # must be exactly a binary + an argv list of strings.
  defp fetch_command(%{"command" => nil}, _action_id), do: {:ok, nil}

  defp fetch_command(%{"command" => %{"binary" => binary, "argv" => argv}}, _action_id)
       when is_binary(binary) and is_list(argv) do
    if Enum.all?(argv, &is_binary/1),
      do: {:ok, %{binary: binary, argv: argv}},
      else: {:error, "action command argv must be a list of strings"}
  end

  defp fetch_command(%{"command" => _bad}, action_id),
    do: {:error, "action #{inspect(action_id)} has a malformed command"}

  defp fetch_command(_raw, _action_id), do: {:ok, nil}

  # The declared args are read back out of the trusted descriptor rather than
  # off the raw entry, so the preview's defaults and `sensitive` flags carry
  # the same validation the trust flow applies to a runner's manifest. A
  # descriptor that doesn't hold up rejects the whole catalog — a half-trusted
  # action would render a command whose masking we can't stand behind.
  defp fetch_args(raw, action_id) do
    case TrustedManifest.from_catalog_actions([raw]) do
      {:ok, %{"actions" => %{^action_id => %{"args_schema" => %{"args" => args}}}}} ->
        {:ok, args}

      _ ->
        {:error, "action #{inspect(action_id)} is not a complete trusted descriptor"}
    end
  end

  # A carried-forward version window is optional; when present each entry
  # must pass the SAME shape checks as the current entry (non-empty version,
  # `sha256:` hash, HTTPS tarball), so a malformed history rejects the whole
  # catalog exactly like a malformed current entry does.
  defp fetch_previous_versions(raw, pack_id) do
    case Map.get(raw, "previous_versions") do
      nil -> {:ok, []}
      versions when is_list(versions) -> reduce_ok(versions, &parse_previous_version(&1, pack_id))
      _ -> {:error, "pack #{inspect(pack_id)} previous_versions must be a list"}
    end
  end

  defp parse_previous_version(%{} = raw, pack_id) do
    with {:ok, version} <- fetch_string(raw, "version"),
         {:ok, content_hash} <- fetch_hash(raw, pack_id),
         {:ok, tarball_url} <- fetch_url(raw, "tarball_url", pack_id) do
      {:ok, %{version: version, content_hash: content_hash, tarball_url: tarball_url}}
    end
  end

  defp parse_previous_version(_raw, pack_id),
    do: {:error, "pack #{inspect(pack_id)} has a previous_versions entry that is not an object"}

  # retired_below is optional; when present it is a version string (the same
  # shape as the current version — non-empty). The dispatch-time retirement
  # comparison lives portal-side in PackBaseline, not in this parser.
  defp fetch_retired_below(raw, pack_id) do
    case Map.get(raw, "retired_below") do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "pack #{inspect(pack_id)} has a malformed retired_below"}
    end
  end

  defp fetch_requires(raw, pack_id) do
    case Map.get(raw, "requires") do
      %{"os" => os, "binaries" => binaries} when is_list(os) and is_list(binaries) ->
        if Enum.all?(os, &is_binary/1) and Enum.all?(binaries, &is_binary/1),
          do: {:ok, os, binaries},
          else: {:error, "pack #{inspect(pack_id)} requires os/binaries must be strings"}

      _ ->
        {:error, "pack #{inspect(pack_id)} has a malformed requires block"}
    end
  end

  defp fetch_detect(raw, pack_id) do
    case Map.get(raw, "detect") do
      %{"binaries" => binaries, "processes" => processes, "ports" => ports}
      when is_list(binaries) and is_list(processes) and is_list(ports) ->
        cond do
          not (Enum.all?(binaries, &is_binary/1) and Enum.all?(processes, &is_binary/1)) ->
            {:error, "pack #{inspect(pack_id)} detect binaries/processes must be strings"}

          not Enum.all?(ports, &(is_integer(&1) and &1 in 1..65_535)) ->
            {:error, "pack #{inspect(pack_id)} detect ports must be 1..65535"}

          true ->
            {:ok, %{binaries: binaries, processes: processes, ports: ports}}
        end

      _ ->
        {:error, "pack #{inspect(pack_id)} has a malformed detect block"}
    end
  end

  # setup is the pack's own authored install guidance. It is OPTIONAL: a
  # catalog published before the field existed carries none, and that catalog
  # is still valid --previous input for the next build, so an absent block
  # decodes to the empty setup rather than failing the whole catalog. A
  # present-but-malformed block still fails closed, like every other field.
  defp fetch_setup(raw, pack_id) do
    case Map.get(raw, "setup") do
      nil ->
        {:ok, empty_setup()}

      %{} = setup ->
        env = Map.get(setup, "env", [])
        notes = Map.get(setup, "notes", [])
        host_access = Map.get(setup, "host_access", [])

        cond do
          not (is_list(env) and Enum.all?(env, &valid_setup_env?/1)) ->
            {:error, "pack #{inspect(pack_id)} setup env entries must each name a string"}

          not (is_list(notes) and Enum.all?(notes, &is_binary/1)) ->
            {:error, "pack #{inspect(pack_id)} setup notes must be strings"}

          true ->
            with {:ok, host_access} <- parse_host_access(host_access, pack_id) do
              {:ok,
               %{
                 summary: optional_string(setup, "summary"),
                 env: Enum.map(env, &parse_setup_env/1),
                 notes: notes,
                 host_access: host_access,
                 verify: optional_string(setup, "verify")
               }}
            end
        end

      _ ->
        {:error, "pack #{inspect(pack_id)} has a malformed setup block"}
    end
  end

  defp empty_setup, do: %{summary: nil, env: [], notes: [], host_access: [], verify: nil}

  defp valid_setup_env?(%{"name" => name}) when is_binary(name), do: true
  defp valid_setup_env?(_), do: false

  defp parse_setup_env(%{"name" => name} = env) do
    %{
      name: name,
      required: Map.get(env, "required") == true,
      description: optional_string(env, "description"),
      default: optional_string(env, "default"),
      example: optional_string(env, "example")
    }
  end

  defp parse_host_access(groups, pack_id) when is_list(groups) do
    initial = {[], MapSet.new()}

    result =
      Enum.reduce_while(groups, {:ok, initial}, fn group, {:ok, {parsed, seen_actions}} ->
        case parse_host_access_group(group, pack_id, seen_actions) do
          {:ok, parsed_group, seen_actions} ->
            {:cont, {:ok, {[parsed_group | parsed], seen_actions}}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    with {:ok, {parsed, _seen_actions}} <- result, do: {:ok, Enum.reverse(parsed)}
  end

  defp parse_host_access(_groups, pack_id),
    do: {:error, "pack #{inspect(pack_id)} setup host_access must be a list"}

  defp parse_host_access_group(
         %{"actions" => actions, "requirement" => requirement, "recipes" => recipes},
         pack_id,
         seen_actions
       )
       when is_list(actions) and actions != [] and is_list(recipes) and recipes != [] do
    with true <- Enum.all?(actions, &valid_setup_command?/1),
         true <- valid_setup_prose?(requirement),
         {:ok, seen_actions} <- put_host_access_actions(actions, seen_actions, pack_id),
         {:ok, recipes} <- parse_host_access_recipes(recipes, pack_id) do
      {:ok, %{actions: actions, requirement: requirement, recipes: recipes}, seen_actions}
    else
      false -> {:error, "pack #{inspect(pack_id)} has malformed setup host_access text"}
      {:error, _} = error -> error
    end
  end

  defp parse_host_access_group(_group, pack_id, _seen_actions),
    do: {:error, "pack #{inspect(pack_id)} has a malformed setup host_access group"}

  defp put_host_access_actions(actions, seen_actions, pack_id) do
    Enum.reduce_while(actions, {:ok, seen_actions}, fn action_id, {:ok, seen} ->
      if MapSet.member?(seen, action_id) do
        {:halt,
         {:error,
          "pack #{inspect(pack_id)} repeats setup host_access action #{inspect(action_id)}"}}
      else
        {:cont, {:ok, MapSet.put(seen, action_id)}}
      end
    end)
  end

  defp parse_host_access_recipes(recipes, pack_id) do
    initial = {[], MapSet.new()}

    result =
      Enum.reduce_while(recipes, {:ok, initial}, fn recipe, {:ok, {parsed, names}} ->
        case parse_host_access_recipe(recipe, pack_id, names) do
          {:ok, parsed_recipe, names} -> {:cont, {:ok, {[parsed_recipe | parsed], names}}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, {parsed, _names}} <- result, do: {:ok, Enum.reverse(parsed)}
  end

  defp parse_host_access_recipe(
         %{"name" => name, "commands" => commands, "verify" => verify, "impact" => impact},
         pack_id,
         names
       )
       when is_list(commands) and commands != [] and is_list(verify) and verify != [] do
    cond do
      not valid_setup_prose?(name) or not valid_setup_prose?(impact) ->
        {:error, "pack #{inspect(pack_id)} has malformed setup host_access recipe prose"}

      not Enum.all?(commands ++ verify, &valid_setup_command?/1) ->
        {:error, "pack #{inspect(pack_id)} has malformed setup host_access commands"}

      MapSet.member?(names, name) ->
        {:error, "pack #{inspect(pack_id)} repeats setup host_access recipe #{inspect(name)}"}

      true ->
        recipe = %{name: name, commands: commands, verify: verify, impact: impact}
        {:ok, recipe, MapSet.put(names, name)}
    end
  end

  defp parse_host_access_recipe(_recipe, pack_id, _names),
    do: {:error, "pack #{inspect(pack_id)} has a malformed setup host_access recipe"}

  defp validate_host_access_actions(setup, actions, pack_id) do
    action_ids = MapSet.new(actions, & &1.id)

    case Enum.find_value(setup.host_access, fn access ->
           Enum.find(access.actions, &(not MapSet.member?(action_ids, &1)))
         end) do
      nil ->
        :ok

      action_id ->
        {:error,
         "pack #{inspect(pack_id)} setup host_access names unknown action #{inspect(action_id)}"}
    end
  end

  defp valid_setup_prose?(value), do: valid_setup_text?(value, true)
  defp valid_setup_command?(value), do: valid_setup_text?(value, false)

  defp valid_setup_text?(value, prose?) when is_binary(value) do
    String.valid?(value) and String.trim(value) != "" and
      value
      |> String.to_charlist()
      |> Enum.all?(&safe_setup_codepoint?(&1, prose?))
  end

  defp valid_setup_text?(_value, _prose?), do: false

  defp safe_setup_codepoint?(codepoint, prose?) do
    prose_whitespace? = prose? and codepoint in [9, 10, 13]

    prose_whitespace? or not unsafe_setup_codepoint?(codepoint)
  end

  # Reject Unicode Control and Format characters. Format includes bidi
  # controls, zero-width text, and BOMs that can make a copied command differ
  # from what an operator sees.
  defp unsafe_setup_codepoint?(codepoint) do
    <<codepoint::utf8>> =~ ~r/[\p{Cc}\p{Cf}]/u
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_hash(raw, pack_id) do
    case Map.get(raw, "content_hash") do
      hash when is_binary(hash) ->
        if Regex.match?(@hash_regex, hash),
          do: {:ok, hash},
          else: {:error, "pack #{inspect(pack_id)} has a malformed content_hash"}

      _ ->
        {:error, "pack #{inspect(pack_id)} is missing content_hash"}
    end
  end

  # HTTPS-only with a host — a cleartext, relative, or `javascript:` URL
  # would ride into a rendered href or the tarball 302 (open redirect).
  defp fetch_url(raw, key, pack_id) do
    case Map.get(raw, key) do
      url when is_binary(url) ->
        case URI.new(url) do
          {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
            {:ok, url}

          _ ->
            {:error, "pack #{inspect(pack_id)} has an unsafe #{key}: #{inspect(url)}"}
        end

      _ ->
        {:error, "pack #{inspect(pack_id)} is missing #{key}"}
    end
  end

  defp fetch_enum(raw, key, allowed, pack_id) do
    value = Map.get(raw, key)

    if value in allowed,
      do: {:ok, value},
      else: {:error, "pack #{inspect(pack_id)} has an invalid #{key}: #{inspect(value)}"}
  end

  defp fetch_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "catalog entry is missing #{key}"}
    end
  end

  defp string_field(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp put_action_ids(action_ids, %Pack{actions: actions}) do
    Enum.reduce_while(actions, {:ok, action_ids}, fn %Action{id: id}, {:ok, seen} ->
      case put_unique(seen, id, "duplicate action id #{inspect(id)}") do
        {:ok, seen} -> {:cont, {:ok, seen}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp put_unique(set, key, message) do
    if MapSet.member?(set, key),
      do: {:error, message},
      else: {:ok, MapSet.put(set, key)}
  end

  defp reduce_ok(items, fun) do
    result =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, acc} <- result, do: {:ok, Enum.reverse(acc)}
  end
end
