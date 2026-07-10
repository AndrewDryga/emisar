defmodule EmisarWeb.PacksRegistry.Catalog do
  @moduledoc """
  Parses and validates a published `catalog.json` document into
  `EmisarWeb.PacksRegistry.Pack` structs.

  The catalog is produced out-of-band by `emisar pack catalog build`
  (the runner's loader is the single source of the content hash, so the
  portal, the runner, and the catalog agree byte-for-byte). This module
  is the portal's trust boundary for that artifact: it is a public,
  attacker-influenceable document served to every `emisar pack install`,
  so a malformed or hostile catalog must be **rejected**, never partially
  loaded. Validation covers the schema version, required fields, unique
  pack and action ids, the `sha256:…` hash shape, safe HTTPS URLs (a
  cleartext or `javascript:` link would ride into a rendered `href` or
  the tarball redirect), and the exec-command template shape.

  Pure — no Repo, no HTTP, no side effects. The cache
  (`EmisarWeb.PacksRegistry.Cache`) owns fetching and last-good caching.
  """

  alias EmisarWeb.PacksRegistry.{Action, Pack}

  @schema_version 1
  @hash_regex ~r/^sha256:[0-9a-f]{64}$/
  @risks ~w(low medium high critical)
  @kinds ~w(exec script)

  @doc """
  Decode + validate a catalog (a JSON string or an already-decoded map)
  into the full pack list, alphabetically by id.

  `{:ok, [Pack.t()]}` on success; `{:error, message}` — a human-readable
  reason for the operational log — on any malformation.
  """
  @spec parse(binary() | map()) :: {:ok, [Pack.t()]} | {:error, String.t()}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> parse(data)
      {:error, _} -> {:error, "catalog is not valid JSON"}
    end
  end

  def parse(%{"schema_version" => @schema_version, "packs" => packs}) when is_list(packs) do
    with {:ok, parsed} <- parse_packs(packs) do
      {:ok, Enum.sort_by(parsed, & &1.id)}
    end
  end

  def parse(%{"schema_version" => version}) do
    {:error, "unsupported catalog schema_version #{inspect(version)} (want #{@schema_version})"}
  end

  def parse(_data), do: {:error, "catalog missing schema_version or packs"}

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

  defp parse_pack(%{} = raw) do
    with {:ok, id} <- fetch_string(raw, "id"),
         {:ok, name} <- fetch_string(raw, "name"),
         {:ok, version} <- fetch_string(raw, "version"),
         {:ok, vendor} <- fetch_string(raw, "vendor"),
         {:ok, source_url} <- fetch_url(raw, "source_url", id),
         {:ok, homepage} <- fetch_url(raw, "homepage", id),
         {:ok, tarball_url} <- fetch_url(raw, "tarball_url", id),
         {:ok, content_hash} <- fetch_hash(raw, id),
         {:ok, requires_os, requires_binaries} <- fetch_requires(raw, id),
         {:ok, detect} <- fetch_detect(raw, id),
         {:ok, actions} <- fetch_actions(raw, id) do
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
         detect: detect,
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
         {:ok, command} <- fetch_command(raw, id) do
      {:ok, %Action{id: id, title: title, kind: kind, risk: risk, command: command}}
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
