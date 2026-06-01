defmodule EmisarWeb.TimeHelpersTest do
  use ExUnit.Case, async: true
  import EmisarWeb.TimeHelpers

  describe "last_used/1" do
    test "renders nil as \"never\" (the convention every LV expects)" do
      assert last_used(nil) == "never"
    end

    test "delegates non-nil timestamps to relative_time/2" do
      ts = DateTime.utc_now() |> DateTime.add(-2 * 60, :second)
      # The relative formatter is locale + window-sensitive; rather than
      # pin its exact text, assert we got the SAME string as the helper
      # we're delegating to. If `relative_time/2` changes, this test
      # keeps passing as long as `last_used/1` keeps delegating.
      assert last_used(ts) == relative_time(ts)
    end
  end

  describe "humanize_errors/1" do
    test "renders a changeset's errors as a single human string" do
      changeset = %Ecto.Changeset{
        errors: [
          email: {"can't be blank", []},
          password: {"should be at least %{count} characters", [count: 12]}
        ]
      }

      msg = humanize_errors(changeset)
      assert msg =~ "email"
      assert msg =~ "can't be blank"
      assert msg =~ "password"
      # `%{count}` interpolation happens — the user shouldn't see the literal.
      refute msg =~ "%{count}"
      assert msg =~ "12"
    end

    test "non-changeset input falls back to a safe default" do
      assert humanize_errors(:something_unexpected) == "Something went wrong"
    end
  end
end
