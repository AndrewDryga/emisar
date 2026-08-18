defmodule EmisarWeb.RunnerConnectControllerTest do
  @moduledoc """
  Route-level coverage for the pre-auth runner registration rate limit.
  """
  use EmisarWeb.ConnCase, async: false

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
