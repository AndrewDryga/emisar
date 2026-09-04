defmodule Emisar.TestHygieneChecksTest do
  @moduledoc """
  Fixture coverage for the two Credo checks scoped to the suite itself: the
  explicit test-context pattern and the ban on `Process.sleep` as
  synchronization.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  @test_file "apps/emisar/test/emisar/sprockets_test.exs"
  @lib_file "apps/emisar/lib/emisar/sprockets.ex"

  setup_all do
    load()
  end

  describe "Emisar.Checks.TestContextPattern" do
    test "flags a test binding its context as a bare variable" do
      source = """
      defmodule Emisar.SprocketsTest do
        use Emisar.DataCase, async: true

        test "reads a sprocket", ctx do
          assert ctx.account
        end
      end
      """

      assert [issue] = issues(context_pattern(), source, @test_file)
      assert issue.check == context_pattern()
      assert issue.trigger == "ctx"
      assert issue.line_no == 4
      assert issue.message =~ "explicit `%{...}` pattern"
    end

    test "allows no context, a map pattern, a bound map pattern, and an ignored one" do
      source = """
      defmodule Emisar.SprocketsTest do
        use Emisar.DataCase, async: true

        test "needs nothing" do
          assert true
        end

        test "reads a sprocket", %{account: account} do
          assert account
        end

        test "reads it again", %{account: account} = context do
          assert account == context.account
        end

        test "ignores the context", _context do
          assert true
        end
      end
      """

      assert issues(context_pattern(), source, @test_file) == []
    end

    test "ignores lib sources" do
      source = """
      defmodule Emisar.Sprockets do
        def test(name, ctx), do: {name, ctx}
      end
      """

      assert issues(context_pattern(), source, @lib_file) == []
    end
  end

  describe "Emisar.Checks.TestNoProcessSleep" do
    test "flags Process.sleep and :timer.sleep in a test" do
      source = """
      defmodule Emisar.SprocketsTest do
        use Emisar.DataCase, async: true

        test "waits for the worker" do
          Process.sleep(50)
          :timer.sleep(50)
        end
      end
      """

      assert triggers(sleep(), source, @test_file) == [":timer.sleep", "Process.sleep"]
      assert [issue | _] = issues(sleep(), source, @test_file)
      assert issue.check == sleep()
      assert issue.message =~ "assert_receive"
    end

    test "allows assert_receive with an explicit timeout" do
      source = """
      defmodule Emisar.SprocketsTest do
        use Emisar.DataCase, async: true

        test "waits for the worker" do
          assert_receive {:sprocket_created, _sprocket}, 500
        end
      end
      """

      assert issues(sleep(), source, @test_file) == []
    end

    test "ignores lib sources, where a sleep is not test synchronization" do
      source = """
      defmodule Emisar.Sprockets do
        def backoff(attempt), do: Process.sleep(attempt * 100)
      end
      """

      assert issues(sleep(), source, @lib_file) == []
    end
  end

  defp context_pattern, do: check("TestContextPattern")
  defp sleep, do: check("TestNoProcessSleep")
end
