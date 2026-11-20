defmodule EmisarWeb.RunnerConnectControllerTest do
  @moduledoc """
  Route-level coverage for the pre-auth runner transport rate limits.
  """
  use EmisarWeb.ConnCase, async: false
  alias Emisar.{Audit, Fixtures, Repo}

  test "refresh authentication records first replacement use with request metadata" do
    runner = Fixtures.Runners.create_runner(connected?: false)
    {_old_raw, previous} = Fixtures.Runners.create_token(runner)
    {raw, replacement} = Fixtures.Runners.create_token(runner, replaces_id: previous.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("user-agent", "emisar-runner/receipt-test")
      |> post(~p"/runner/token/refresh", %{})

    assert json_response(conn, 409)["error"] == "not_due"
    assert event = Repo.one(Audit.Event)
    assert event.event_type == "runner.credential_rotated"
    assert event.account_id == runner.account_id
    assert event.payload["token_id"] == replacement.id
    assert event.user_agent == "emisar-runner/receipt-test"
    assert event.ip_address
    refute event.payload["token_hash"]
    refute conn.resp_body =~ raw
  end

  test "a malformed-UTF-8 bearer is unauthorized, not a server error" do
    malformed = "Bearer " <> :binary.copy(<<0xFF>>, 40)

    register =
      build_conn()
      |> put_req_header("authorization", malformed)
      |> post(~p"/runner/register", %{
        "hostname" => "demo-1",
        "group" => "demo",
        "external_id" => "ext-#{System.unique_integer([:positive])}"
      })

    refresh =
      build_conn()
      |> put_req_header("authorization", malformed)
      |> post(~p"/runner/token/refresh", %{})

    assert register.status == 401
    assert refresh.status == 401
  end

  test "the token refresh and the socket upgrade share one per-IP cap" do
    Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

    # Both verify a presented token before they authenticate anything, so an
    # anonymous caller could spend the credential lookup and its usage stamp for
    # free. One bucket covers the pair — spending it on refreshes closes the
    # upgrade too.
    responses = for _ <- 1..120, do: post(build_conn(), ~p"/runner/token/refresh", %{})

    assert Enum.map(responses, & &1.status) == List.duplicate(401, 120)

    rejected = get(build_conn(), ~p"/runner/socket/websocket")
    assert rejected.status == 429
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert rejected.resp_body =~ "rate_limited"
  end

  test "POST /runner/register returns 429 after the per-IP cap" do
    Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

    responses = for _ <- 1..30, do: post(build_conn(), ~p"/runner/register", %{})

    assert Enum.map(responses, & &1.status) == List.duplicate(401, 30)

    rejected = post(build_conn(), ~p"/runner/register", %{})
    assert rejected.status == 429
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert rejected.resp_body =~ "rate_limited"
  end
end
