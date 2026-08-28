defmodule Emisar.BrowserInput do
  @moduledoc """
  Normalization for operator-typed browser form params, shared by the
  changesets that cast them.

  A create form posts raw browser strings: an untouched optional field arrives
  as `""` rather than absent, and `<input type="datetime-local">` emits
  `YYYY-MM-DDTHH:MM` (no seconds, no zone), which Ecto cannot cast to
  `:utc_datetime_usec`. Both key shapes are normalized so a browser map and an
  internal atom-keyed map mean the same thing.

  This lived as byte-identical private blocks in the ApiKey and EnrollmentKey
  changesets; a fix to one copy would have missed the other.
  """

  @doc """
  Normalizes `attrs`, treating each field in `blank:` as an optional string
  (`""` → `nil`) and each field in `expiry:` as a browser datetime-local value.
  Fields are matched by atom or string key, whichever shape the caller posts.
  """
  def normalize(attrs, spec) do
    blank = names(spec[:blank])
    expiry = names(spec[:expiry])

    Map.new(attrs, fn
      {field, value} = pair ->
        cond do
          name(field) in blank -> {field, blank_to_nil(value)}
          name(field) in expiry -> {field, expiry(value)}
          true -> pair
        end
    end)
  end

  defp names(nil), do: []
  defp names(fields), do: Enum.map(fields, &Atom.to_string/1)

  defp name(field) when is_atom(field), do: Atom.to_string(field)
  defp name(field) when is_binary(field), do: field
  defp name(field), do: field

  @doc "`\"\"` and whitespace-only input mean the field was left empty."
  def blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  def blank_to_nil(value), do: value

  @doc """
  An operator typing "expires Dec 25 at 10am" gets 10:00 UTC that day — the
  browser sends no zone, and the form labels the field UTC rather than have the
  server guess an offset. Anything that is not a browser minute stamp (an
  already-typed `%DateTime{}`, a full timestamp, or garbage) passes through for
  Ecto to cast or reject, so a malformed expiry can never quietly become "no
  expiry" — which would hand out a credential with no cutoff.
  """
  def expiry(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      expires_at -> parse_browser_expiry(expires_at)
    end
  end

  def expiry(value), do: value

  defp parse_browser_expiry(value) do
    case DateTime.from_iso8601(value <> ":00Z") do
      {:ok, expires_at, _offset} -> expires_at
      {:error, _reason} -> value
    end
  end
end
