defmodule Emisar.Runs.RunnerErrorTest do
  use ExUnit.Case, async: true
  alias Emisar.RequestContext
  alias Emisar.Runs.RunnerError

  @account Ecto.UUID.generate()
  @runner Ecto.UUID.generate()

  describe "new/4" do
    test "strips control/format characters from code and message" do
      rlo = <<0x202E::utf8>>

      error =
        RunnerError.new(
          @account,
          @runner,
          %{code: "pack" <> rlo <> "_failed", message: "boot" <> rlo <> "log"},
          %RequestContext{}
        )

      assert error.code == "pack_failed"
      assert error.message == "bootlog"
    end

    test "a non-string diagnostic becomes nil" do
      error = RunnerError.new(@account, @runner, %{code: 42, message: %{}}, %RequestContext{})

      assert error.code == nil
      assert error.message == nil
    end
  end
end
