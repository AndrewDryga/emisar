defmodule EmisarWeb.MCP.ResponseBudgetTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ResponseBudget

  test "measures the complete mirrored JSON-RPC representation" do
    small = %{ok: true, runs: [%{stdout: "status"}], next_cursor: nil}
    assert ResponseBudget.fits_payload?(small)

    escape_heavy = %{
      ok: true,
      runs: Enum.map(1..100, &%{run_id: &1, stdout: String.duplicate("\\", 1_000)}),
      next_cursor: nil
    }

    refute ResponseBudget.fits_payload?(escape_heavy)

    frame = %{
      jsonrpc: "2.0",
      id: 1,
      result: ResponseBudget.fixed_result(escape_heavy, false)
    }

    assert {:error, :response_too_large} = ResponseBudget.encode_frame(frame)
  end

  test "bounds every echoed request id used by the page budget" do
    assert ResponseBudget.valid_request_id?(String.duplicate("i", 4_096))
    refute ResponseBudget.valid_request_id?(String.duplicate("i", 4_097))

    assert ResponseBudget.valid_request_id?(String.to_integer(String.duplicate("9", 4_096)))
    refute ResponseBudget.valid_request_id?(String.to_integer(String.duplicate("9", 4_097)))
  end
end
