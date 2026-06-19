defmodule EmisarWeb.ReturnTo do
  @moduledoc """
  Validates a post-sign-in `return_to` against the only shape we ever honor — a
  local `/app/<slug-or-id>` path. The branded sign-in pages thread it through the
  password form, the magic link, and the password reset so those land back on the
  right team. It is always attacker-influenceable (a form field / query param), so
  every consumer runs it through here: never an open redirect, and the slug gate
  still re-authorizes membership on arrival, so a forged ref just 404s / falls back.
  """

  # A bare /app/<ref> with no trailing path — the branded landing for one team.
  # `<ref>` is a slug or a UUID; both match [a-z0-9-]+.
  @pattern ~r{^/app/[a-z0-9-]+$}

  @doc "The value if it's a local `/app/<ref>` target, else `nil`."
  def app_path(value) when is_binary(value) do
    if value =~ @pattern, do: value, else: nil
  end

  def app_path(_), do: nil
end
