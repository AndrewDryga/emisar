defmodule EmisarWeb.CachedBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers`. Security boundaries that verify
  request bytes or exact JSON value slices must retain the body before the
  ordinary parser consumes it.

  For all other routes this is a no-op pass-through. Cached bodies double the
  request's transient memory, so the allow-list stays deliberately small and
  every listed route enforces its own request-size limit.
  """

  @cached_body_limits %{
    "/api/mcp/rpc" => 128 * 1024,
    "/webhooks/paddle" => 1024 * 1024
  }

  # Bodies we bound WITHOUT caching — the route verifies no bytes, so retaining
  # a copy would double the request's memory for nothing.
  #
  # Postmark authenticates with Basic Auth, not a body signature, and its
  # bounce/complaint events are a few hundred bytes; 64 KiB is generous headroom
  # for an unsigned endpoint anyone on the internet can POST to.
  @bounded_body_limits %{"/webhooks/postmark" => 64 * 1024}

  # SCIM is unauthenticated until the controller pipeline runs, so Plug's ~8 MB
  # default was parsed before the bearer was even looked at — the rate limiter's
  # per-request allowance multiplied by that is a lot of bytes an anonymous
  # caller can make us hold. The largest legitimate SCIM body is a group
  # replace, which the domain already caps at 5,000 member ids; 2 MB clears that
  # with room to spare.
  @bounded_body_prefixes %{"/scim/v2/" => 2 * 1024 * 1024}

  def read_body(conn, opts) do
    opts = bound_length(opts, body_limit(conn.request_path))

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        maybe_cache_body(conn, body)

      {:more, body, conn} ->
        # Preserve Plug.Parsers' size limit behavior. The JSON parser converts
        # this to a controlled :too_large response; caching a partial signed
        # payload would be both useless and misleading.
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cache_body(conn, body) do
    if Map.has_key?(@cached_body_limits, conn.request_path) do
      {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
    else
      {:ok, body, conn}
    end
  end

  defp body_limit(path) do
    case Map.get(@cached_body_limits, path) do
      nil -> bounded_limit(path)
      limit -> limit
    end
  end

  defp bounded_limit(path) do
    case Map.get(@bounded_body_limits, path) do
      nil -> prefix_limit(path)
      limit -> limit
    end
  end

  defp prefix_limit(path) do
    Enum.find_value(@bounded_body_prefixes, fn {prefix, limit} ->
      if String.starts_with?(path, prefix), do: limit
    end)
  end

  defp bound_length(opts, nil), do: opts

  defp bound_length(opts, limit) do
    Keyword.update(opts, :length, limit, &min(&1, limit))
  end
end
