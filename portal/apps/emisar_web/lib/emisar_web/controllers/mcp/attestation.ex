defmodule EmisarWeb.MCP.Attestation do
  @moduledoc """
  Validates the shape and bounds of a client attestation before relaying it to
  a runner. The runner remains responsible for signature and certificate
  verification; this module only keeps malformed envelopes from becoming
  action arguments or unbounded persisted payloads.
  """

  @max_field_bytes 512
  @max_scope_labels 32

  @doc "Returns a bounded attestation envelope, or nil when the input is malformed."
  @spec normalize(term()) :: map() | nil
  def normalize(%{} = attestation) do
    sig = attestation["sig"]
    nonce = attestation["nonce"]
    issued_at = attestation["issued_at"]
    cert = normalize_cert(attestation["cert"])

    if bounded_string?(sig) and bounded_string?(nonce) and bounded_string?(issued_at) and cert do
      %{"sig" => sig, "nonce" => nonce, "issued_at" => issued_at, "cert" => cert}
    end
  end

  def normalize(_), do: nil

  # The certificate is key-blind here: the runner verifies the CA signature.
  # Restrict fields, shape, and size before persisting or relaying it.
  defp normalize_cert(%{} = cert) do
    required = ["ca_id", "key_id", "public_key", "valid_from", "valid_until", "serial", "sig"]
    fields = Map.take(cert, required)
    scope = Map.get(cert, "scope", %{})

    if map_size(fields) == length(required) and
         Enum.all?(fields, fn {_key, value} -> bounded_string?(value) end) and
         valid_scope?(scope) do
      Map.put(fields, "scope", scope)
    end
  end

  defp normalize_cert(_), do: nil

  # Scope is {group?: bounded string, labels?: %{bounded string => bounded string}}.
  defp valid_scope?(%{} = scope) do
    group_ok =
      case Map.fetch(scope, "group") do
        :error -> true
        {:ok, group} -> bounded_string?(group)
      end

    labels_ok =
      case Map.fetch(scope, "labels") do
        :error ->
          true

        {:ok, %{} = labels} ->
          map_size(labels) <= @max_scope_labels and
            Enum.all?(labels, fn {key, value} ->
              bounded_string?(key) and bounded_string?(value)
            end)

        {:ok, _} ->
          false
      end

    group_ok and labels_ok and Enum.all?(Map.keys(scope), &(&1 in ["group", "labels"]))
  end

  defp valid_scope?(_), do: false

  defp bounded_string?(value), do: is_binary(value) and byte_size(value) <= @max_field_bytes
end
