defmodule Emisar.OAuth.Jobs.CleanupTest do
  @moduledoc """
  The daily sweep that prunes expired OAuth authorization codes (single-use,
  60s artifacts). Drives the worker's `execute/1` end-to-end against a
  backdated code.
  """
  use Emisar.DataCase, async: true
  alias Emisar.Crypto
  alias Emisar.Fixtures
  alias Emisar.OAuth
  alias Emisar.OAuth.{AuthorizationCode, Client, Token}
  alias Emisar.OAuth.Jobs.Cleanup

  @redirect "https://claude.ai/api/mcp/auth_callback"

  defp issue_code!(subject) do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "C", "redirect_uris" => [@redirect]})

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {:ok, _code} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp",
          "resource" => Emisar.PublicUrl.url("/api/mcp/rpc")
        },
        subject
      )
  end

  defp issue_tokens!(subject) do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "C", "redirect_uris" => [@redirect]})

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {:ok, code} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp offline_access",
          "resource" => Emisar.PublicUrl.url("/api/mcp/rpc")
        },
        subject
      )

    {:ok, tokens} =
      OAuth.exchange_code(%{
        "code" => code,
        "client_id" => client.id,
        "redirect_uri" => @redirect,
        "code_verifier" => verifier
      })

    tokens
  end

  test "execute/1 prunes expired authorization codes and returns :ok" do
    {_user, _account, subject} = Fixtures.Subjects.owner_subject()
    issue_code!(subject)

    # A freshly-issued code (60s TTL) isn't expired — the sweep is a no-op.
    assert :ok = Cleanup.execute([])
    assert Repo.aggregate(AuthorizationCode.Query.all(), :count) == 1

    # Backdate it past expiry; now the worker prunes it.
    past = DateTime.add(DateTime.utc_now(), -120, :second)
    {1, _} = AuthorizationCode.Query.all() |> Repo.update_all(set: [expires_at: past])

    assert :ok = Cleanup.execute([])
    refute Repo.exists?(AuthorizationCode.Query.all())
  end

  test "execute/1 prunes abandoned never-authorized client registrations" do
    {:ok, client} =
      OAuth.register_client(%{"client_name" => "Drive-by", "redirect_uris" => [@redirect]})

    # A fresh registration is within the window — the sweep keeps it.
    assert :ok = Cleanup.execute([])
    assert Repo.reload(client)

    # Backdate the registration past the 30-day abandonment window → pruned.
    past = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
    {1, _} = Client.Query.by_id(client.id) |> Repo.update_all(set: [inserted_at: past])

    assert :ok = Cleanup.execute([])
    refute Repo.reload(client)
  end

  test "execute/1 prunes OAuth tokens after their refresh grant expires" do
    {_user, _account, subject} = Fixtures.Subjects.owner_subject()
    tokens = issue_tokens!(subject)
    token = Repo.get_by!(Token, access_token_hash: Crypto.hash(tokens.access_token))

    # An expired access token can still be refreshed, so the cleanup keeps the
    # row until the longer-lived refresh grant expires too.
    past = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update!(Ecto.Changeset.change(token, access_expires_at: past))
    assert :ok = Cleanup.execute([])
    assert Repo.reload(token)

    Repo.update!(Ecto.Changeset.change(token, refresh_expires_at: past))
    assert :ok = Cleanup.execute([])
    refute Repo.reload(token)

    # A second tick is an idempotent no-op.
    assert :ok = Cleanup.execute([])
  end
end

defmodule Emisar.OAuth.Jobs.CleanupLogTest do
  @moduledoc """
  The swept-count log lines. `async: false` because it raises the global Logger
  level to `:info` (the test env defaults to `:warning`) to observe an info log.
  """
  use Emisar.DataCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.Fixtures
  alias Emisar.OAuth
  alias Emisar.OAuth.AuthorizationCode
  alias Emisar.OAuth.Jobs.Cleanup

  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  defp issue_expired_code! do
    {_user, _account, subject} = Fixtures.Subjects.owner_subject()

    {:ok, client} =
      OAuth.register_client(%{"client_name" => "C", "redirect_uris" => [@redirect]})

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    {:ok, _} =
      OAuth.issue_code(
        client,
        %{
          "redirect_uri" => @redirect,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp",
          "resource" => Emisar.PublicUrl.url("/api/mcp/rpc")
        },
        subject
      )

    past = DateTime.add(DateTime.utc_now(), -120, :second)
    {1, _} = AuthorizationCode.Query.all() |> Repo.update_all(set: [expires_at: past])
    :ok
  end

  # the swept-count lines are logged ONLY when something was
  # deleted (each guarded by `if n > 0`). A no-op sweep over an empty/fresh table
  # (every daily tick when nothing aged out) stays silent rather than logging
  # "codes_swept 0 / unused_clients_swept 0"; a sweep that prunes a code logs it.
  test "execute/1 logs swept counts only when rows were deleted" do
    # Nothing to delete (no codes, no abandoned clients) → silent.
    silent = capture_log(fn -> assert :ok = Cleanup.execute([]) end)
    refute silent =~ "oauth_cleanup.codes_swept"
    refute silent =~ "oauth_cleanup.unused_clients_swept"

    :ok = issue_expired_code!()

    # An expired code → the codes line is logged.
    noisy = capture_log(fn -> assert :ok = Cleanup.execute([]) end)
    assert noisy =~ "oauth_cleanup.codes_swept"
  end
end
