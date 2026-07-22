defmodule Emisar.CompatTest do
  # async: false — these tests set the global Emisar.Compat policy.
  use ExUnit.Case, async: false
  alias Emisar.Compat

  defp put_policy(opts) do
    Emisar.Config.put_override(:emisar, Emisar.Compat, opts)
  end

  describe "runner_status/1" do
    setup do
      put_policy(runner_minimum: ">= 0.4.0", runner_recommended: ">= 0.5.0")
    end

    test "at or above the recommended version is supported" do
      assert Compat.runner_status("0.5.0") == :supported
      assert Compat.runner_status("1.2.3") == :supported
    end

    test "below recommended but at or above minimum is outdated" do
      assert Compat.runner_status("0.4.0") == :outdated
      assert Compat.runner_status("0.4.9") == :outdated
    end

    test "below the minimum is unsupported" do
      assert Compat.runner_status("0.3.9") == :unsupported
      assert Compat.runner_status("0.1.0") == :unsupported
    end

    test "a missing version is unknown, never unsupported" do
      assert Compat.runner_status(nil) == :unknown
      assert Compat.runner_status("") == :unknown
    end

    test "a malformed version is unknown, never unsupported" do
      assert Compat.runner_status("garbage") == :unknown
      assert Compat.runner_status("v0.4.0") == :unknown
      assert Compat.runner_status("0.4") == :unknown
    end

    test "a pre-release sorts before its release, per semver precedence" do
      # 0.5.0-rc1 < 0.5.0, so it hasn't reached the recommended line yet.
      assert Compat.runner_status("0.5.0-rc1") == :outdated
      # 0.4.0-rc1 < 0.4.0, so it falls below the minimum.
      assert Compat.runner_status("0.4.0-rc1") == :unsupported
    end

    test "surrounding whitespace is tolerated" do
      assert Compat.runner_status("  0.5.0  ") == :supported
    end
  end

  describe "runner_status/1 with no configured policy" do
    setup do
      put_policy([])
    end

    test "any parseable version is supported when no thresholds are set" do
      assert Compat.runner_status("0.0.1") == :supported
    end

    test "a missing version is still unknown" do
      assert Compat.runner_status(nil) == :unknown
    end
  end

  describe "runner_status/1 with a malformed configured requirement" do
    setup do
      put_policy(runner_minimum: "not-a-requirement")
    end

    test "raises rather than silently accepting every version" do
      assert_raise Version.InvalidRequirementError, fn -> Compat.runner_status("0.5.0") end
    end
  end

  describe "mcp_status/1" do
    setup do
      put_policy(mcp_minimum: ">= 0.4.0", mcp_recommended: ">= 0.5.0")
    end

    test "classifies the bridge version against the MCP policy" do
      assert Compat.mcp_status("0.5.0") == :supported
      assert Compat.mcp_status("0.4.0") == :outdated
      assert Compat.mcp_status("0.1.0") == :unsupported
      assert Compat.mcp_status(nil) == :unknown
    end
  end

  describe "enforce_runners?/0 and enforce_mcp?/0" do
    test "default to false (warn-only)" do
      put_policy(runner_minimum: ">= 0.4.0")
      refute Compat.enforce_runners?()
      refute Compat.enforce_mcp?()
    end

    test "reflect the configured enforcement flags" do
      put_policy(runner_enforce: true, mcp_enforce: false)
      assert Compat.enforce_runners?()
      refute Compat.enforce_mcp?()
    end
  end

  describe "configured requirement accessors" do
    test "expose the raw requirement string for operator-facing messages" do
      put_policy(
        runner_minimum: ">= 0.4.0",
        runner_recommended: ">= 0.5.0",
        mcp_minimum: "~> 0.5",
        mcp_recommended: ">= 0.6.0"
      )

      assert Compat.runner_minimum() == ">= 0.4.0"
      assert Compat.runner_recommended() == ">= 0.5.0"
      assert Compat.mcp_minimum() == "~> 0.5"
      assert Compat.mcp_recommended() == ">= 0.6.0"
    end

    test "are nil when unset" do
      put_policy([])
      assert Compat.runner_minimum() == nil
      assert Compat.runner_recommended() == nil
      assert Compat.mcp_minimum() == nil
      assert Compat.mcp_recommended() == nil
    end
  end
end
