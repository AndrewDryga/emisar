# Rule: a group of operator-tunable settings is ONE embedded `settings` jsonb value, not a column-per-toggle

**Rule.** When a schema starts accumulating admin-flippable settings — booleans
(`require_mfa`, `require_sso`), caps/limits (`max_grant_lifetime_seconds`), small
enums — they go in **one** embedded value object (`<Schema>.Settings`) stored in a
`settings :map` (jsonb) column, **not** a top-level column per toggle. The embed
owns its own `changeset/2`. Read it through **one** accessor that returns the embed
(`fetch_account_settings/1`) — never a `fetch_<schema>_<field>/1` per setting. The
embed is **non-nil by construction** (DB `default: %{}` + a create-time default) so
`x.settings.<field>` is always safe. Field-aware permission/audit gates inspect the
**nested** embed changeset (`changeset.changes.settings`), not top-level keys.

**Why.** A column-per-toggle grows the schema, the changeset cast list, AND the
context (a bespoke `fetch_<field>` + Query pipeline + `case` to read one value)
every time product adds a setting — three files and a migration for a boolean. It
also drifts: each accessor re-derives the same "load account, pull one field"
shape. One embed collapses that to: add a field on the value object + its UI. The
settings group is a value object — it has no table, no query, no authorizer, no
Repo touch — so it's the one schema that does NOT `use Emisar, :schema` (which would
force a UUID PK + timestamps): a plain `use Ecto.Schema` + `@primary_key false`.
Because every setting in the group shares one permission tier, "did the embed
change?" answers the field-aware security gate in one line.

**✅ Good**

```elixir
# account/settings.ex — the value object owns its fields AND its changeset
defmodule Emisar.Accounts.Account.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :require_mfa, :boolean, default: false
    field :require_sso, :boolean, default: false
    field :max_grant_lifetime_seconds, :integer
  end

  @fields ~w[require_mfa require_sso max_grant_lifetime_seconds]a
  def changeset(%__MODULE__{} = settings, attrs),
    do: settings |> cast(attrs, @fields) |> validate_number(:max_grant_lifetime_seconds, greater_than: 0)
end

# account.ex — one column, merge-on-update
embeds_one :settings, Emisar.Accounts.Account.Settings, on_replace: :update

# account/changeset.ex — cast_embed; default so the embed is never nil
def update(%Account{} = account, attrs),
  do: account |> cast(attrs, @fields) |> cast_embed(:settings, with: &Account.Settings.changeset/2) |> changeset()

# accounts.ex — ONE accessor returns the embed (tagged tuple)
def fetch_account_settings(account_id) do
  if Repo.valid_uuid?(account_id) do
    Account.Query.not_deleted() |> Account.Query.by_id(account_id) |> Repo.fetch(Account.Query)
    |> case do
      {:ok, %Account{settings: settings}} -> {:ok, settings}
      {:error, :not_found} -> {:error, :not_found}
    end
  else
    {:error, :not_found}
  end
end

# field-aware gate inspects the NESTED embed changeset
defp security_setting_changed?(%Ecto.Changeset{changes: changes}), do: Map.has_key?(changes, :settings)
```

```elixir
# caller reads the field it needs off the embed — no per-field context fn
defp account_grant_lifetime_cap(account_id) do
  case Accounts.fetch_account_settings(account_id) do
    {:ok, settings} -> settings.max_grant_lifetime_seconds
    {:error, :not_found} -> nil
  end
end
```

**❌ Bad**

```elixir
# A column per toggle on the schema...
schema "accounts" do
  field :require_mfa, :boolean, default: false
  field :require_sso, :boolean, default: false
  field :max_grant_lifetime_seconds, :integer
end

# ...and a bespoke context fn + Query pipeline + case to read ONE of them,
# with an awkward `cap | {:error, :not_found}` mixed return.
def fetch_account_max_grant_lifetime(account_id) do
  Account.Query.not_deleted() |> Account.Query.by_id(account_id) |> Repo.fetch()
  |> case do
    {:ok, %Account{max_grant_lifetime_seconds: cap}} -> cap
    {:error, :not_found} -> {:error, :not_found}
  end
end
# The next setting repeats all of this. The schema, the @update_fields list, and
# the context all grow per toggle.
```

**How it's enforced.** Judgment + review (not Credo): when a schema gains a 2nd/3rd
admin-flippable setting, or a `fetch_<schema>_<field>/1` appears, that's the smell —
fold the group into a `<Schema>.Settings` embed. The migration that introduces the
column follows the repo's migration rules (edit-original pre-prod; a **forward
corrective** add-column + `jsonb_build_object` backfill + drop-columns once the table
is on prod — see the `ConsolidateAccountSettings` migration).
