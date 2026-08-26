defmodule EmisarWeb.BillingIntentTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.BillingIntent

  @salt "billing plan-cycle intent v1"

  test "round-trips only Team monthly and annual choices" do
    month = BillingIntent.sign("team", :month)
    year = BillingIntent.sign("team", :year)

    assert BillingIntent.verify(month) == {:ok, %{plan: "team", cycle: :month}}
    assert BillingIntent.verify(year) == {:ok, %{plan: "team", cycle: :year}}

    assert {:ok, {:v1, "team", "month"}} =
             Phoenix.Token.verify(EmisarWeb.Endpoint, @salt, month, max_age: :infinity)
  end

  test "rejects tampering, another purpose, stale tokens, and unknown payload values" do
    valid = BillingIntent.sign("team", :month)

    tampered =
      valid
      |> String.to_charlist()
      |> List.update_at(10, fn
        ?A -> ?B
        _other -> ?A
      end)
      |> List.to_string()

    wrong_purpose =
      Phoenix.Token.sign(EmisarWeb.Endpoint, "another purpose", {:v1, "team", "month"})

    stale =
      Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, {:v1, "team", "month"},
        signed_at: System.system_time(:second) - 86_401
      )

    invalid_payloads = [
      {:v2, "team", "month"},
      {:v1, "enterprise", "month"},
      {:v1, "team", "weekly"},
      {:v1, "team", :month},
      %{"plan" => "team", "cycle" => "month", "price_id" => "pri_attacker"}
    ]

    assert BillingIntent.verify(tampered) == {:error, :invalid}
    assert BillingIntent.verify(wrong_purpose) == {:error, :invalid}
    assert BillingIntent.verify(stale) == {:error, :invalid}

    for payload <- invalid_payloads do
      token = Phoenix.Token.sign(EmisarWeb.Endpoint, @salt, payload)
      assert BillingIntent.verify(token) == {:error, :invalid}
    end
  end
end
