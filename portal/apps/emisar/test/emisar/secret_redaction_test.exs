defmodule Emisar.SecretRedactionTest do
  @moduledoc """
  Every secret-bearing schema must keep its credential field(s) out of
  `inspect/1` output — a hash or secret that surfaces in a log line, a crash
  dump, or an error message is a credential disclosure. Ecto's
  `field …, redact: true` drives the redaction; these are the regression guards
  that fail if a field loses the flag, or a new secret field/schema skips it.
  """
  use ExUnit.Case, async: true

  # Every `redact: true` field in the schema layer, grouped by schema. The
  # completeness test below fails if this drifts from what the schemas actually
  # declare — so a new secret field can't be added without a leak guard.
  @redacted [
    {Emisar.ApiKeys.ApiKey, [:key_hash]},
    {Emisar.Runners.EnrollmentKey, [:key_hash]},
    {Emisar.Runners.Token, [:token_hash]},
    {Emisar.OAuth.Client, [:client_secret_hash]},
    {Emisar.OAuth.Token, [:access_token_hash, :refresh_token_hash]},
    {Emisar.OAuth.AuthorizationCode, [:code_hash]},
    {Emisar.SSO.IdentityProvider, [:client_secret, :scim_token_hash]},
    {Emisar.Users.User, [:mfa_secret, :mfa_recovery_codes]}
  ]

  for {schema, fields} <- @redacted, field <- fields do
    test "#{inspect(schema)} keeps #{field} out of inspect/1 output" do
      sentinel = "DO-NOT-LEAK-#{unquote(field)}"
      struct = struct!(unquote(schema), %{unquote(field) => sentinel})

      refute inspect(struct) =~ sentinel
    end
  end

  test "the guard list matches every redact:true field the schema layer declares" do
    {:ok, modules} = :application.get_key(:emisar, :modules)

    declared =
      for mod <- modules,
          Code.ensure_loaded?(mod),
          function_exported?(mod, :__schema__, 1),
          field <- mod.__schema__(:redact_fields),
          into: MapSet.new(),
          do: {mod, field}

    guarded =
      for {schema, fields} <- @redacted, field <- fields, into: MapSet.new(), do: {schema, field}

    assert MapSet.equal?(declared, guarded),
           "redaction guard out of sync — un-guarded: " <>
             "#{inspect(MapSet.difference(declared, guarded))}, " <>
             "stale: #{inspect(MapSet.difference(guarded, declared))}"
  end
end
