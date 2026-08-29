defmodule EmisarWeb.RunnerConnectControllerTest do
  @moduledoc """
  Route-level coverage for the pre-auth runner transport rate limits.
  """
  use EmisarWeb.ConnCase, async: false

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
