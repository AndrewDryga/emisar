defmodule EmisarWeb.ChangesetErrors do
  @moduledoc "Renders changeset errors as messages, interpolating only the placeholders each message contains."

  # Error options also carry metadata such as `type: {:array, :string}` that no
  # message references and `to_string/1` cannot convert, so substituting every
  # option crashed the request on a malformed list element.
  def messages(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn placeholder, key ->
        case Enum.find(opts, fn {name, _value} -> to_string(name) == key end) do
          {_name, value} -> to_string(value)
          nil -> placeholder
        end
      end)
    end)
  end
end
