defmodule Emisar.Auth.UserToken do
  @moduledoc """
  Long-lived (session) + ephemeral (magic link / reset / confirm) user
  tokens. Stored hashed; the raw token is only ever returned to the
  caller at creation time.
  """

  use Ecto.Schema
  import Ecto.Query

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @hash_algorithm :sha256
  @rand_size 32

  # Validity windows. The user can configure these later via runtime
  # config; defaults err on the side of "short enough not to be the
  # weakest link if a phone is lost."
  @session_validity_in_days 60
  @confirm_validity_in_days 7
  @reset_validity_in_days 1
  @magic_link_validity_in_minutes 15
  @change_email_validity_in_days 7

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Build an opaque session token. Returns `{raw_token, struct}`.

  The raw token is the bearer the client holds; the struct persists
  only `sha256(raw)`, so a DB leak does not let an attacker reuse the
  cookie. This matches the hashed-token model used for magic-link /
  password-reset / confirm contexts.

  Optional `metadata` (map of `ip_address`, `user_agent`) is stamped
  onto the row so the Profile sessions list can show "Started 7h ago
  from 1.2.3.4 (Mozilla/5.0 …)" instead of just a UUID slice.
  """
  def build_session_token(user, metadata \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    digest = :crypto.hash(@hash_algorithm, token)

    {token,
     %__MODULE__{
       token: digest,
       context: "session",
       user_id: user.id,
       metadata: normalize_metadata(metadata)
     }}
  end

  defp normalize_metadata(meta) when is_map(meta) do
    %{
      "ip_address" => to_string_or_nil(meta[:ip_address] || meta["ip_address"]),
      "user_agent" => to_string_or_nil(meta[:user_agent] || meta["user_agent"])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_metadata(_), do: %{}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(s) when is_binary(s), do: s
  defp to_string_or_nil(other), do: to_string(other)

  @doc """
  Checks the session token; returns the user query that fetches the
  matching user and asserts the token hasn't expired.
  """
  def verify_session_token_query(token) do
    digest = :crypto.hash(@hash_algorithm, token)

    query =
      from t in by_token_and_context_query(digest, "session"),
        join: u in assoc(t, :user),
        where: t.inserted_at > ago(@session_validity_in_days, "day"),
        select: u

    {:ok, query}
  end

  @doc """
  Deletes a session token by raw value (cookie value), looking it up
  by digest. Returns the count of rows removed.
  """
  def delete_session_token_query(raw) do
    digest = :crypto.hash(@hash_algorithm, raw)
    from(t in __MODULE__, where: t.token == ^digest and t.context == "session")
  end

  @doc "Build a hashed, single-use token for a non-session context."
  def build_hashed_token(user, context, sent_to \\ nil, metadata \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hashed,
       context: context,
       sent_to: sent_to,
       metadata: metadata,
       user_id: user.id
     }}
  end

  @doc "Verifies a single-use hashed token (magic link, password reset, etc.)."
  def verify_hashed_token_query(raw, context) do
    case Base.url_decode64(raw, padding: false) do
      {:ok, decoded} ->
        hashed = :crypto.hash(@hash_algorithm, decoded)
        days = days_for_context(context)

        query =
          from t in by_token_and_context_query(hashed, context),
            join: u in assoc(t, :user),
            where: t.inserted_at > ago(^days, "day"),
            select: {u, t}

        {:ok, query}

      :error ->
        :error
    end
  end

  defp by_token_and_context_query(token, context) do
    from t in __MODULE__, where: t.token == ^token and t.context == ^context
  end

  @doc """
  All session tokens for a user, newest first. Used by the profile
  page to show "where you're currently signed in".
  """
  def sessions_for_user_query(%Emisar.Accounts.User{id: user_id}) do
    from t in __MODULE__,
      where: t.user_id == ^user_id and t.context == "session",
      order_by: [desc: t.inserted_at]
  end

  @doc "Query selecting a specific session token by `id` scoped to `user`."
  def session_by_id_for_user_query(%Emisar.Accounts.User{id: user_id}, token_id) do
    from t in __MODULE__,
      where: t.id == ^token_id and t.user_id == ^user_id and t.context == "session"
  end

  @doc """
  Query selecting every session token for the user EXCEPT the one
  matching `keep_token_digest`. Used by Profile's "sign out everywhere
  else" so the caller's current cookie keeps working.
  """
  def other_sessions_for_user_query(%Emisar.Accounts.User{id: user_id}, keep_token_digest) do
    from t in __MODULE__,
      where: t.user_id == ^user_id and t.context == "session" and t.token != ^keep_token_digest
  end

  @doc "Query that deletes all tokens for a user."
  def by_user_and_contexts_query(user, :all),
    do: from(t in __MODULE__, where: t.user_id == ^user.id)

  def by_user_and_contexts_query(user, contexts) when is_list(contexts),
    do: from(t in __MODULE__, where: t.user_id == ^user.id and t.context in ^contexts)

  defp days_for_context("confirm"), do: @confirm_validity_in_days
  defp days_for_context("reset_password"), do: @reset_validity_in_days
  defp days_for_context("magic_link"), do: @magic_link_validity_in_minutes |> minutes_to_days()
  defp days_for_context("change_email:" <> _), do: @change_email_validity_in_days

  defp minutes_to_days(minutes), do: minutes / (24 * 60)
end
