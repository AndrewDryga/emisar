defmodule Emisar.Runs.Attestation do
  @moduledoc """
  The bounded bridge-signed `run_action` envelope, bound to one exact dispatch.

  A validated value is the only thing that can satisfy signature-required
  dispatch or become signed audit state, so the domain never has to trust that
  some boundary already checked an arbitrary map. Validation rejects a malformed
  or ambiguous envelope and one whose signed facts differ from the dispatch the
  portal would relay.

  The portal is deliberately not a signature authority: the runner verifies the
  customer CA, the certificate, the Ed25519 signature, freshness, its own local
  target identity, and the replay nonce.
  """
  alias Emisar.Crypto

  @version "emisar-attestation-v5"
  @tool "run_action"
  @max_header_bytes 8_192
  @max_runner_refs 16
  @max_runner_ref_bytes 113
  # Matches `$defs.reason` in the MCP schema. A narrower bound here rejects an
  # attestation the bridge legitimately signed over a schema-valid reason; the
  # 8 KiB header cap above is the real budget.
  @max_reason_chars 2_000
  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/
  @lower_hex_32 ~r/\A[0-9a-f]{32}\z/
  @lower_hex_64 ~r/\A[0-9a-f]{64}\z/
  # The claim signature is lower-hex, and its LENGTH depends on the leaf key:
  # an Ed25519 signature is exactly 64 bytes, while an ECDSA P-256 signature is
  # ASN.1 DER and varies around 70. Pinning 128 characters here would refuse
  # every P-256-signed dispatch at the portal, before the runner — the only
  # cryptographic authority — ever saw it.
  @lower_hex_signature ~r/\A(?:[0-9a-f]{2}){64,80}\z/

  @envelope_fields ~w(
    version tool portal_origin action_id pack_ref args_sha256 runner_refs reason
    evidence_sha256 expected_sha256
    operation_id sig nonce issued_at cert_chain
  )
  # The leaf plus at most one intermediate, each standard-base64 DER. The bound
  # is generous enough for an RSA-issued chain and small enough that a malformed
  # envelope cannot make the portal parse megabytes.
  @max_chain_certs 2
  @max_chain_entry_bytes 8_192

  @enforce_keys [:envelope]
  defstruct [:envelope]

  @opaque t :: %__MODULE__{envelope: map()}

  @type facts :: %{
          required(:action_id) => String.t(),
          required(:pack_ref) => String.t(),
          required(:args_raw) => binary(),
          required(:runner_refs) => [String.t()],
          required(:reason) => String.t(),
          required(:operation_id) => String.t(),
          required(:portal_origin) => String.t()
        }

  @doc """
  Validates one raw `Emisar-Attestation` header list against the exact facts of
  the dispatch it would authorize.

  Returns the validated envelope, `nil` when no header was sent, or
  `{:error, :invalid_attestation}` for anything bounded-but-wrong: a malformed
  or ambiguous envelope, an out-of-bounds field, or a signed fact that disagrees
  with this call.
  """
  @spec validate([String.t()], facts()) :: {:ok, t() | nil} | {:error, :invalid_attestation}
  def validate([], _facts), do: {:ok, nil}

  def validate([header], facts) when is_binary(header) do
    with :ok <- bounded_header(header),
         {:ok, raw} <- Base.url_decode64(header, padding: false),
         {:ok, envelope} <- decode_unambiguous(raw),
         {:ok, normalized} <- normalize(envelope),
         :ok <- compare(normalized, facts) do
      {:ok, %__MODULE__{envelope: normalized}}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  def validate(_headers, _facts), do: {:error, :invalid_attestation}

  @doc "Internal — the normalized v4 envelope the portal persists and relays verbatim."
  @spec envelope(t()) :: map()
  def envelope(%__MODULE__{envelope: envelope}), do: envelope

  defp bounded_header(header) do
    if header != "" and byte_size(header) <= @max_header_bytes,
      do: :ok,
      else: {:error, :invalid_attestation}
  end

  # A duplicate key anywhere makes the signed claim ambiguous — one reader takes
  # the field the bridge signed while another takes the one an attacker
  # appended. The ordered decode keeps every pair, so a key set that shrinks
  # when deduplicated IS the duplicate, at any depth.
  defp decode_unambiguous(raw) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:ok, decoded} -> unambiguous(decoded)
      {:error, _reason} -> {:error, :invalid_attestation}
    end
  end

  defp unambiguous(%Jason.OrderedObject{values: pairs}) do
    {keys, values} = Enum.unzip(pairs)

    with true <- length(Enum.uniq(keys)) == length(keys),
         {:ok, values} <- unambiguous_values(values) do
      {:ok, keys |> Enum.zip(values) |> Map.new()}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  defp unambiguous(values) when is_list(values), do: unambiguous_values(values)
  defp unambiguous(value), do: {:ok, value}

  defp unambiguous_values(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, converted} ->
      case unambiguous(value) do
        {:ok, value} -> {:cont, {:ok, [value | converted]}}
        {:error, :invalid_attestation} -> {:halt, {:error, :invalid_attestation}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, :invalid_attestation} -> {:error, :invalid_attestation}
    end
  end

  defp normalize(%{} = envelope) do
    with :ok <- exact_keys(envelope, @envelope_fields),
         true <- envelope["version"] == @version,
         true <- envelope["tool"] == @tool,
         :ok <- bounded_string(envelope["portal_origin"], 1, 2_048),
         :ok <- bounded_string(envelope["action_id"], 1, 128),
         :ok <- bounded_string(envelope["pack_ref"], 1, 256),
         true <- matches?(envelope["args_sha256"], @lower_hex_64),
         true <- matches?(envelope["evidence_sha256"], @lower_hex_64),
         true <- matches?(envelope["expected_sha256"], @lower_hex_64),
         {:ok, runner_refs} <- canonical_runner_refs(envelope["runner_refs"]),
         true <- runner_refs == envelope["runner_refs"],
         :ok <- bounded_chars(envelope["reason"], 1, @max_reason_chars),
         true <- matches?(envelope["operation_id"], @operation_id),
         true <- matches?(envelope["sig"], @lower_hex_signature),
         true <- matches?(envelope["nonce"], @lower_hex_32),
         :ok <- timestamp(envelope["issued_at"]),
         :ok <- cert_chain(envelope["cert_chain"]) do
      {:ok, envelope}
    else
      _ -> {:error, :invalid_attestation}
    end
  end

  defp normalize(_envelope), do: {:error, :invalid_attestation}

  # The chain is opaque to the portal: it is bounded and confirmed to be
  # decodable base64, then relayed verbatim. Judging its trust here would
  # duplicate — and could disagree with — the runner, which is the only
  # cryptographic authority for a certificate.
  defp cert_chain(chain)
       when is_list(chain) and length(chain) in 1..@max_chain_certs do
    if Enum.all?(chain, &decodable_certificate?/1),
      do: :ok,
      else: {:error, :invalid_attestation}
  end

  defp cert_chain(_chain), do: {:error, :invalid_attestation}

  defp decodable_certificate?(entry) do
    bounded_string?(entry, 1, @max_chain_entry_bytes) and
      match?({:ok, _der}, Base.decode64(entry))
  end

  defp compare(envelope, facts) do
    expected_refs = Enum.sort(facts.runner_refs)

    # The approver-facing narrative is bound by digest, not carried — it
    # runs to 6,000 characters against an 8 KiB envelope. Comparing here is
    # the point of binding it: the text an operator is shown when deciding
    # is the text the bridge signed, and an absent field hashes too, so the
    # control plane cannot ADD a justification the caller never gave.
    if envelope["portal_origin"] == facts.portal_origin and
         envelope["action_id"] == facts.action_id and
         envelope["pack_ref"] == facts.pack_ref and
         envelope["args_sha256"] == Crypto.hash_hex(facts.args_raw) and
         envelope["runner_refs"] == expected_refs and
         envelope["reason"] == facts.reason and
         envelope["evidence_sha256"] == Crypto.hash_hex(facts.evidence || "") and
         envelope["expected_sha256"] == Crypto.hash_hex(facts.expected || "") and
         envelope["operation_id"] == facts.operation_id do
      :ok
    else
      {:error, :attestation_mismatch}
    end
  end

  defp canonical_runner_refs(refs) when is_list(refs) and length(refs) in 1..@max_runner_refs do
    if Enum.all?(refs, &bounded_string?(&1, 1, @max_runner_ref_bytes)) and
         MapSet.size(MapSet.new(refs)) == length(refs) do
      {:ok, Enum.sort(refs)}
    else
      {:error, :invalid_attestation}
    end
  end

  defp canonical_runner_refs(_refs), do: {:error, :invalid_attestation}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _ -> {:error, :invalid_attestation}
    end
  end

  defp timestamp(_value), do: {:error, :invalid_attestation}

  defp exact_keys(map, fields) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_attestation}
  end

  defp bounded_string(value, min, max) do
    if bounded_string?(value, min, max),
      do: :ok,
      else: {:error, :invalid_attestation}
  end

  defp bounded_chars(value, min, max) do
    if is_binary(value) and String.length(value) in min..max,
      do: :ok,
      else: {:error, :invalid_attestation}
  end

  defp bounded_string?(value, min, max),
    do: is_binary(value) and byte_size(value) in min..max

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)
end
