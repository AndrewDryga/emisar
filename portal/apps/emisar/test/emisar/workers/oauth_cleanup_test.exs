defmodule Emisar.Workers.OAuthCleanupTest do
  @moduledoc """
  The daily sweep that prunes expired OAuth authorization codes (single-use,
  60s artifacts). Drives the worker's `perform/1` end-to-end against a
  backdated code.
  """
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.OAuth
  alias Emisar.OAuth.AuthorizationCode
  alias Emisar.Workers.OAuthCleanup

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
          "resource" => "https://emisar.dev/api/mcp/rpc"
        },
        subject
      )
  end

  test "perform/1 prunes expired authorization codes and returns :ok" do
    {_user, _account, subject} = owner_subject_fixture()
    issue_code!(subject)

    # A freshly-issued code (60s TTL) isn't expired — the sweep is a no-op.
    assert :ok = OAuthCleanup.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(AuthorizationCode.Query.all(), :count) == 1

    # Backdate it past expiry; now the worker prunes it.
    past = DateTime.add(DateTime.utc_now(), -120, :second)
    {1, _} = AuthorizationCode.Query.all() |> Repo.update_all(set: [expires_at: past])

    assert :ok = OAuthCleanup.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(AuthorizationCode.Query.all(), :count) == 0
  end
end
