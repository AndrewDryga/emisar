defmodule Emisar.StyleChecksTest do
  @moduledoc """
  Fixture coverage for the Credo checks that carry the house writing style:
  acronym casing, alias grouping, wrapped `do:`, contiguous module headers,
  pattern-over-`if` dispatch, pipes in branch heads, capture syntax, and spelled
  out bindings.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT. The
  two line-scanning checks also get a probe whose `@moduledoc` DOCUMENTS the
  banned shape — documentation is not code, and reading it as code is how both
  first fired on their own `explanations:` examples.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  @context "apps/emisar/lib/emisar/sprockets.ex"

  setup_all do
    load()
  end

  describe "Emisar.Checks.AcronymModuleCase" do
    test "flags a CamelCased acronym in a module name" do
      source = """
      defmodule EmisarWeb.Scim.Controller do
      end
      """

      assert [issue] = issues(acronym(), source, @context)
      assert issue.check == acronym()
      assert issue.trigger == "Scim"
      assert issue.line_no == 1
      assert issue.message =~ "SCIM"
    end

    test "flags every miscased acronym segment in an alias" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.Sso.Oidc
        alias EmisarWeb.Mcp
      end
      """

      assert triggers(acronym(), source, @context) == ["Mcp", "Oidc", "Sso"]
    end

    test "allows all-caps acronyms, ApiKeys, and snake_case identifiers" do
      source = """
      defmodule EmisarWeb.SCIM.Controller do
        alias Emisar.ApiKeys
        alias Emisar.SSO.OIDC
        alias EmisarWeb.MCP

        def path, do: "/scim/v2"
        def token(scim_token), do: scim_token
      end
      """

      assert issues(acronym(), source, @context) == []
    end
  end

  describe "Emisar.Checks.MultilineAliasGroup" do
    test "flags a grouped alias the formatter expanded across lines" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.SSO.{
          Authorizer,
          DirectoryGroupMember
        }
      end
      """

      assert [issue] = issues(alias_group(), source, @context)
      assert issue.check == alias_group()
      assert issue.line_no == 2
      assert issue.message =~ "single-line grouped aliases"
    end

    test "allows single-line groups and plain aliases" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.SSO.{Authorizer, DirectoryGroupMember, GroupRoleMapping}
        alias Emisar.SSO.{IdentityProvider, OIDC, UserIdentity}
        alias Emisar.Sprockets.Sprocket
      end
      """

      assert issues(alias_group(), source, @context) == []
    end
  end

  describe "Emisar.Checks.MultilineDoColon" do
    test "flags a do: the formatter wrapped onto its own line" do
      source = """
      defmodule Emisar.Sprockets do
        defp reduced?(a, b),
          do:
            not MapSet.subset?(perms(a), perms(b))
      end
      """

      assert [issue] = issues(do_colon(), source, @context)
      assert issue.check == do_colon()
      assert issue.line_no == 3
      assert issue.message =~ "do … end"
    end

    test "allows a fitting one-liner and a do … end block" do
      source = """
      defmodule Emisar.Sprockets do
        defp reduced?(a, b), do: MapSet.subset?(a, b)

        defp perms(role) do
          Enum.sort(role.permissions)
        end
      end
      """

      assert issues(do_colon(), source, @context) == []
    end

    test "reads a documented ❌ example as documentation, not as code" do
      source = """
      defmodule Emisar.Sprockets do
        @moduledoc \"""
        The banned shape:

            defp reduced?(a, b),
              do:
                not MapSet.subset?(perms(a), perms(b))
        \"""

        defp reduced?(a, b), do: MapSet.subset?(a, b)
      end
      """

      assert issues(do_colon(), source, @context) == []
    end
  end

  describe "Emisar.Checks.NoBlankBetweenDirectives" do
    test "flags a blank line sandwiched between two directives" do
      source = """
      defmodule Emisar.Sprockets do
        use Emisar, :context

        alias Emisar.Accounts
      end
      """

      assert [issue] = issues(blank_directives(), source, @context)
      assert issue.check == blank_directives()
      assert issue.line_no == 3
      assert issue.message =~ "contiguous block"
    end

    test "allows a contiguous header, a why-comment, and the formatter's multi-line blank" do
      source = """
      defmodule Emisar.Sprockets do
        use Emisar, :context
        # The endpoint has to be compiled before the routes it verifies.

        use Phoenix.VerifiedRoutes,
          endpoint: EmisarWeb.Endpoint

        alias Emisar.Accounts
      end
      """

      assert issues(blank_directives(), source, @context) == []
    end

    test "reads a documented ❌ example as documentation, not as code" do
      source = """
      defmodule Emisar.Sprockets do
        @moduledoc \"""
        The banned shape:

            use Emisar.DataCase, async: true

            alias Emisar.Accounts
        \"""
        use Emisar, :context
        alias Emisar.Accounts
      end
      """

      assert issues(blank_directives(), source, @context) == []
    end
  end

  describe "Emisar.Checks.NoIfOnArgField" do
    test "flags a closure dispatching on its argument's field truthiness" do
      source = """
      defmodule Emisar.Sprockets do
        def labels(sprockets) do
          Enum.map(sprockets, fn sprocket ->
            if sprocket.name, do: sprocket.name, else: "unnamed"
          end)
        end
      end
      """

      assert [issue] = issues(if_on_arg_field(), source, @context)
      assert issue.check == if_on_arg_field()
      assert issue.trigger == "if sprocket.name"
      assert issue.line_no == 3
      assert issue.message =~ "function clause heads"
    end

    test "allows a captured two-clause function and a genuinely computed condition" do
      source = """
      defmodule Emisar.Sprockets do
        def labels(sprockets), do: Enum.map(sprockets, &label/1)

        def sizes(sprockets) do
          Enum.map(sprockets, fn sprocket ->
            if Enum.empty?(sprocket.tags), do: 0, else: length(sprocket.tags)
          end)
        end

        defp label(%Sprocket{name: nil}), do: "unnamed"
        defp label(%Sprocket{name: name}), do: name
      end
      """

      assert issues(if_on_arg_field(), source, @context) == []
    end
  end

  describe "Emisar.Checks.NoPipeInBranchHead" do
    test "flags a pipe in a with, for, and case head" do
      source = """
      defmodule Emisar.Sprockets do
        def fetch(id) do
          with {:ok, sprocket} <- Sprocket.Query.by_id(id) |> Repo.fetch() do
            {:ok, sprocket}
          end
        end

        def ids, do: for(sprocket <- Sprocket.Query.all() |> Repo.list(), do: sprocket.id)

        def kind(queryable) do
          case queryable |> Repo.list() do
            [] -> :empty
            _rows -> :some
          end
        end
      end
      """

      assert triggers(pipe_in_branch_head(), source, @context) == ["<-", "<-", "case"]
      assert [issue | _] = issues(pipe_in_branch_head(), source, @context)
      assert issue.check == pipe_in_branch_head()
      assert issue.message =~ "bind the pipeline to a name"
    end

    test "allows a pipeline bound above the head" do
      source = """
      defmodule Emisar.Sprockets do
        def fetch(id) do
          queryable = Sprocket.Query.by_id(id)

          with {:ok, sprocket} <- Repo.fetch(queryable) do
            {:ok, sprocket}
          end
        end
      end
      """

      assert issues(pipe_in_branch_head(), source, @context) == []
    end

    test "ignores test sources" do
      source = """
      defmodule Emisar.SprocketsTest do
        def kind(queryable) do
          case queryable |> Repo.list() do
            [] -> :empty
            _rows -> :some
          end
        end
      end
      """

      assert issues(pipe_in_branch_head(), source, "apps/emisar/test/emisar/sprockets_test.exs") ==
               []
    end
  end

  describe "Emisar.Checks.PreferCaptureClosure" do
    test "flags single-call forwarding closures" do
      source = """
      defmodule Emisar.Sprockets do
        def names(sprockets), do: Enum.map(sprockets, fn sprocket -> sprocket.name end)
        def strings(sprockets), do: Enum.map(sprockets, fn sprocket -> to_string(sprocket) end)
        def labels(sprockets), do: Enum.map(sprockets, fn sprocket -> Sprocket.label(sprocket, :short) end)
      end
      """

      assert triggers(capture_closure(), source, @context) == [
               "fn sprocket ->",
               "fn sprocket ->",
               "fn sprocket ->"
             ]

      assert [issue | _] = issues(capture_closure(), source, @context)
      assert issue.check == capture_closure()
      assert issue.message =~ "capture syntax"
    end

    test "allows a capture, a constructor body, a multi-arg closure, and a matching head" do
      source = """
      defmodule Emisar.Sprockets do
        def names(sprockets), do: Enum.map(sprockets, & &1.name)
        def pairs(sprockets), do: Enum.map(sprockets, fn sprocket -> {sprocket.id, sprocket.name} end)
        def sum(sprockets), do: Enum.reduce(sprockets, 0, fn sprocket, acc -> acc + sprocket.size end)
        def matched(sprockets), do: Enum.map(sprockets, fn %Sprocket{name: name} -> name end)
      end
      """

      assert issues(capture_closure(), source, @context) == []
    end
  end

  describe "Emisar.Checks.ShortBindings" do
    test "flags abbreviated parameters, assignments, and DSL bindings" do
      source = """
      defmodule Emisar.Sprockets do
        def apply_changes(cs, attrs) do
          q = Sprocket.Query.all()
          Repo.list(q, attrs)
        end

        def scoped(queryable) do
          where(queryable, [group_members: gm], gm.account_id == ^1)
        end
      end
      """

      found = issues(short_bindings(), source, @context)

      assert found |> Enum.map(& &1.trigger) |> Enum.sort() == ["cs", "gm", "q"]
      assert Enum.all?(found, &(&1.check == short_bindings()))
      assert Enum.find(found, &(&1.trigger == "cs")).message =~ "spell the binding out"
      assert Enum.find(found, &(&1.trigger == "gm")).message =~ "single letter"
    end

    test "allows spelled-out names and a single-letter DSL binding" do
      source = """
      defmodule Emisar.Sprockets do
        def apply_changes(changeset, attrs) do
          queryable = Sprocket.Query.all()
          Repo.list(queryable, attrs)
        end

        def scoped(queryable) do
          where(queryable, [group_members: g], g.account_id == ^1)
        end
      end
      """

      assert issues(short_bindings(), source, @context) == []
    end
  end

  defp acronym, do: check("AcronymModuleCase")
  defp alias_group, do: check("MultilineAliasGroup")
  defp do_colon, do: check("MultilineDoColon")
  defp blank_directives, do: check("NoBlankBetweenDirectives")
  defp if_on_arg_field, do: check("NoIfOnArgField")
  defp pipe_in_branch_head, do: check("NoPipeInBranchHead")
  defp capture_closure, do: check("PreferCaptureClosure")
  defp short_bindings, do: check("ShortBindings")
end
