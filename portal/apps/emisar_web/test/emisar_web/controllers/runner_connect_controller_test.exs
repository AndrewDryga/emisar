defmodule EmisarWeb.RunnerConnectControllerTest do
  @moduledoc """
  Route-level coverage for the pre-auth runner registration rate limit.
  """
  use EmisarWeb.ConnCase, async: false

  defp enable_rate_limiting do
    previous = Application.get_env(:emisar_web, :rate_limit_enabled, true)
    Application.put_env(:emisar_web, :rate_limit_enabled, true)
    on_exit(fn -> Application.put_env(:emisar_web, :rate_limit_enabled, previous) end)
  end

  test "POST /runner/register returns 429 after the per-IP cap" do
    enable_rate_limiting()

    responses = for _ <- 1..30, do: post(build_conn(), ~p"/runner/register", %{})

    assert Enum.map(responses, & &1.status) == List.duplicate(401, 30)

    rejected = post(build_conn(), ~p"/runner/register", %{})
    assert rejected.status == 429
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert rejected.resp_body =~ "rate_limited"
  end
end
