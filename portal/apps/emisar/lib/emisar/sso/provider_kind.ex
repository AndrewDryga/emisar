defmodule Emisar.SSO.ProviderKind do
  @moduledoc """
  The identity-provider kinds emisar supports, and the facts that are FIXED per
  kind: fixed or regional issuers, the claim its tokens carry a stable identity
  in, and whether it can push SCIM directory sync.

  One list drives the `kind` enum, the console's picker, and the normalization
  `Emisar.SSO` applies on create and update — so a kind can't be supported in one
  place and unknown in another, and the console can't be the only thing enforcing
  an invariant a crafted request would skip.
  """

  # Google serves one issuer for every customer, and has no inbound SCIM for a
  # custom app — members provision on first sign-in, so directory sync is not
  # offered rather than offered and unreachable.
  #
  # Entra's `sub` is PAIRWISE (a different value per application), so sign-in and
  # directory sync only agree on `oid`, its immutable object id.
  #
  # Keycloak ships no outbound SCIM client of its own, but our endpoint is plain
  # SCIM 2.0 + a bearer, so a third-party extension can drive it — refusing the
  # connection would block an operator who already runs one.
  @metadata [
    google_workspace: %{
      fixed_issuer: "https://accounts.google.com",
      identifier_claim: :sub,
      supports_scim?: false
    },
    okta: %{fixed_issuer: nil, identifier_claim: :sub, supports_scim?: true},
    entra: %{fixed_issuer: nil, identifier_claim: :oid, supports_scim?: true},
    jumpcloud: %{fixed_issuer: nil, identifier_claim: :sub, supports_scim?: true},
    keycloak: %{fixed_issuer: nil, identifier_claim: :sub, supports_scim?: true},
    openid_connect: %{fixed_issuer: nil, identifier_claim: :sub, supports_scim?: true}
  ]

  @kinds Keyword.keys(@metadata)
  @by_name Map.new(@kinds, &{Atom.to_string(&1), &1})
  @jumpcloud_regions [
    {"United States", "https://oauth.id.jumpcloud.com/"},
    {"Europe", "https://oauth.id.eu.jumpcloud.com/"},
    {"India", "https://oauth.id.in.jumpcloud.com/"}
  ]
  @preset_issuers Enum.flat_map(@metadata, fn {_kind, metadata} ->
                    List.wrap(metadata.fixed_issuer)
                  end) ++ Enum.map(@jumpcloud_regions, &elem(&1, 1))

  @doc "Every supported kind, in the order the console offers them."
  def all, do: @kinds

  @doc "Known fixed or regional issuers that a provider-type switch may clear."
  def preset_issuers, do: @preset_issuers

  @doc "Supported region names and exact issuers; empty when the kind has no region choice."
  def issuer_regions(kind) when kind in [:jumpcloud, "jumpcloud"], do: @jumpcloud_regions
  def issuer_regions(_kind), do: []

  @doc """
  A kind's fixed facts, from the atom or its string form:
  `{:ok, %{kind, fixed_issuer, identifier_claim, supports_scim?}} | :error`.
  Anything unrecognized is `:error` — a submitted kind never becomes an atom.
  """
  def fetch(kind) when is_atom(kind) do
    case Keyword.fetch(@metadata, kind) do
      {:ok, metadata} -> {:ok, Map.put(metadata, :kind, kind)}
      :error -> :error
    end
  end

  def fetch(kind) when is_binary(kind) do
    case Map.fetch(@by_name, kind) do
      {:ok, kind} -> fetch(kind)
      :error -> :error
    end
  end

  def fetch(_kind), do: :error

  @doc "True only for a known kind that can push SCIM directory sync — unknown fails closed."
  def supports_scim?(kind) do
    case fetch(kind) do
      {:ok, metadata} -> metadata.supports_scim?
      :error -> false
    end
  end
end
