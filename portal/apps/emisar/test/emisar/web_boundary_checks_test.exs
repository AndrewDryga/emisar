defmodule Emisar.WebBoundaryChecksTest do
  @moduledoc """
  AST regression coverage for the two Credo checks that keep `apps/emisar_web`
  an adapter: `Emisar.Checks.WebNoNestedDomainCalls` and
  `Emisar.Checks.WebNoChangesetConstruction`.

  Credo only loads `credo/checks/**` when `mix credo` runs, so a silent AST
  regression there would go unnoticed until someone reintroduced the shape the
  checks exist to stop. These tests parse a probe source at a web path and run
  each check directly, asserting both what must fire and what must not.
  """
  use ExUnit.Case, async: true
  alias Credo.SourceFile

  # The checks are path-scoped, so every probe is parsed as a web source file.
  @web_file "apps/emisar_web/lib/emisar_web/probe.ex"

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:credo)

    for file <- ~w[web_no_nested_domain_calls.ex web_no_changeset_construction.ex] do
      Code.require_file(Path.join([__DIR__, "..", "..", "..", "..", "credo", "checks", file]))
    end

    :ok
  end

  describe "Emisar.Checks.WebNoNestedDomainCalls" do
    test "flags a fully qualified nested domain call" do
      source = """
      defmodule EmisarWeb.Probe do
        def packs, do: Emisar.Catalog.PublishedRegistry.list()
      end
      """

      assert triggers(nested_check(), source) == ["Catalog.PublishedRegistry.list"]
    end

    test "flags a nested call reached through the top-level context alias" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        def pack(id), do: Catalog.PublishedRegistry.get(id)
      end
      """

      assert triggers(nested_check(), source) == ["Catalog.PublishedRegistry.get"]
    end

    test "flags a deep alias, including one renamed with as:" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Accounts.RunnerAccess
        alias Emisar.Runs.RunnerError, as: Failure

        def none, do: RunnerAccess.none()
        def failure(attrs), do: Failure.new("a", "b", attrs, nil)
      end
      """

      assert triggers(nested_check(), source) == [
               "Accounts.RunnerAccess.none",
               "Runs.RunnerError.new"
             ]
    end

    test "flags every branch of a grouped alias" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Runbooks.{Authoring, Naming}

        def definition(command), do: Authoring.build_v1(command)
        def slug(title), do: Naming.resolve_slug(title, nil)
      end
      """

      assert triggers(nested_check(), source) == [
               "Runbooks.Authoring.build_v1",
               "Runbooks.Naming.resolve_slug"
             ]
    end

    test "flags a captured nested domain function" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        def loader, do: &Catalog.PublishedRegistry.list/0
        def typer, do: &Catalog.PublishedRegistry.Pack.t/0
      end
      """

      assert triggers(nested_check(), source) == [
               "Catalog.PublishedRegistry.Pack.t",
               "Catalog.PublishedRegistry.list"
             ]
    end

    test "flags a runtime t/0 while allowing one in a type attribute" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        @type pack :: Catalog.PublishedRegistry.Pack.t()
        @typep ref :: Emisar.Catalog.PublishedRegistry.Pack.t()
        @opaque token :: Catalog.PublishedRegistry.Pack.t()
        @type wrong :: Catalog.PublishedRegistry.Pack.kind()

        @spec kind(ref) :: String.t()
        def kind(pack), do: pack.kind

        def rebuild, do: Catalog.PublishedRegistry.Pack.t()
      end
      """

      assert triggers(nested_check(), source) == [
               "Catalog.PublishedRegistry.Pack.kind",
               "Catalog.PublishedRegistry.Pack.t"
             ]
    end

    test "flags a nested call written inside a ~H template" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        def render(assigns) do
          ~H\"""
          <ul>
            <li :for={pack <- Catalog.PublishedRegistry.list()}>{pack.name}</li>
          </ul>
          \"""
        end

        def compact(assigns), do: ~H"<span>{Emisar.Runs.RunnerError.new(@run)}</span>"
      end
      """

      assert triggers(nested_check(), source) == [
               "Catalog.PublishedRegistry.list",
               "Runs.RunnerError.new"
             ]
    end

    test "reports a ~H issue on the template line that carries the call" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        def render(assigns) do
          ~H\"""
          <div>
            {Catalog.PublishedRegistry.Pack.t()}
          </div>
          \"""
        end
      end
      """

      assert [issue] = issues(nested_check(), source, @web_file)
      assert issue.trigger == "Catalog.PublishedRegistry.Pack.t"
      assert issue.line_no == 7
    end

    test "allows top-level context calls, remote t/0 types, and struct references" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Accounts
        alias Emisar.Catalog

        @spec pack(String.t()) :: Catalog.PublishedRegistry.Pack.t() | nil
        def pack(id), do: Catalog.get_published_pack(id)

        @spec source_url(Emisar.Catalog.PublishedRegistry.Pack.t()) :: String.t()
        def source_url(%Catalog.PublishedRegistry.Pack{source_url: url}), do: url

        def label(%Accounts.RunnerAccess{mode: :none}), do: "No runners"
        def none, do: %Accounts.RunnerAccess{mode: :none, groups: [], runner_ids: []}
      end
      """

      assert triggers(nested_check(), source) == []
    end

    test "allows the Emisar.Auth.Subject carrier, aliased or fully qualified" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Auth.Subject

        def build(user, account), do: Subject.for_user(user, account, :password, [])
        def rebuild(user, account), do: Emisar.Auth.Subject.for_user(user, account, nil)
      end
      """

      assert triggers(nested_check(), source) == []
    end

    test "does not treat EmisarWeb as Emisar" do
      source = """
      defmodule EmisarWeb.Probe do
        alias EmisarWeb.MCP.Service

        def call, do: Service.Handler.dispatch(:ping)
        def other, do: EmisarWeb.CoreComponents.Icon.render(%{})
      end
      """

      assert triggers(nested_check(), source) == []
    end

    test "ignores sources outside apps/emisar_web/lib" do
      source = """
      defmodule Emisar.Probe do
        def packs, do: Emisar.Catalog.PublishedRegistry.list()
      end
      """

      assert issues(nested_check(), source, "apps/emisar/lib/emisar/probe.ex") == []
    end
  end

  describe "Emisar.Checks.WebNoChangesetConstruction" do
    test "flags every mutating Ecto.Changeset call" do
      source = """
      defmodule EmisarWeb.Probe do
        def build(changeset, attrs) do
          changeset
          |> Ecto.Changeset.cast(attrs, [:name])
          |> Ecto.Changeset.put_change(:slug, "x")
          |> Ecto.Changeset.validate_required([:name])
          |> Ecto.Changeset.unique_constraint(:slug)
          |> Ecto.Changeset.add_error(:name, "is invalid")
        end

        def apply(changeset), do: Ecto.Changeset.apply_action(changeset, :insert)
        def applied(changeset), do: Ecto.Changeset.apply_changes(changeset)
        def changed(record), do: Ecto.Changeset.change(record, %{})
      end
      """

      assert triggers(changeset_check(), source) == [
               "Ecto.Changeset.add_error",
               "Ecto.Changeset.apply_action",
               "Ecto.Changeset.apply_changes",
               "Ecto.Changeset.cast",
               "Ecto.Changeset.change",
               "Ecto.Changeset.put_change",
               "Ecto.Changeset.unique_constraint",
               "Ecto.Changeset.validate_required"
             ]
    end

    test "flags an aliased changeset mutation, plain or renamed" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Ecto.Changeset
        alias Ecto.Changeset, as: Form

        def add(changeset), do: Changeset.add_error(changeset, :name, "is invalid")
        def put(changeset), do: Form.put_change(changeset, :slug, "x")
      end
      """

      assert triggers(changeset_check(), source) == [
               "Ecto.Changeset.add_error",
               "Ecto.Changeset.put_change"
             ]
    end

    test "flags a captured changeset mutation" do
      source = """
      defmodule EmisarWeb.Probe do
        def rejecter, do: &Ecto.Changeset.add_error/4
        def reader, do: &Ecto.Changeset.get_field/2
      end
      """

      assert triggers(changeset_check(), source) == ["Ecto.Changeset.add_error"]
    end

    test "flags import Ecto.Changeset, plain and scoped" do
      source = """
      defmodule EmisarWeb.Probe do
        import Ecto.Changeset
        import Ecto.Changeset, only: [cast: 3]
        import Ecto.Changeset, except: [add_error: 4]
      end
      """

      assert triggers(changeset_check(), source) == [
               "import Ecto.Changeset",
               "import Ecto.Changeset",
               "import Ecto.Changeset"
             ]
    end

    test "flags a changeset mutation written inside a ~H template" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Ecto.Changeset

        def render(assigns) do
          ~H\"""
          <p>{Ecto.Changeset.get_field(@form.source, :issuer)}</p>
          <p>{Changeset.put_change(@form.source, :slug, "x")}</p>
          \"""
        end
      end
      """

      assert triggers(changeset_check(), source) == ["Ecto.Changeset.put_change"]
    end

    test "allows read-only inspection, to_form, and marking the submit action" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Ecto.Changeset

        def issuer(form), do: Ecto.Changeset.get_field(form.source, :issuer)
        def errors(changeset), do: Ecto.Changeset.traverse_errors(changeset, & &1)
        def change(changeset), do: Changeset.get_change(changeset, :name)
        def changed?(changeset), do: Changeset.changed?(changeset, :name)
        def form(changeset), do: Phoenix.Component.to_form(changeset, as: "account")
        def submitted(changeset), do: Map.put(changeset, :action, :insert)
        def validated(changeset), do: %{changeset | action: :validate}
      end
      """

      assert triggers(changeset_check(), source) == []
    end

    test "ignores sources outside apps/emisar_web/lib" do
      source = """
      defmodule Emisar.Probe do
        def add(changeset), do: Ecto.Changeset.add_error(changeset, :name, "is invalid")
      end
      """

      assert issues(changeset_check(), source, "apps/emisar/lib/emisar/probe.ex") == []
    end
  end

  # Resolved at runtime so the compiler never sees a literal reference to a
  # module that only exists once `setup_all` requires it — which is also why
  # `safe_concat` can insist the atom already exists.
  defp nested_check, do: Module.safe_concat([:Emisar, :Checks, :WebNoNestedDomainCalls])
  defp changeset_check, do: Module.safe_concat([:Emisar, :Checks, :WebNoChangesetConstruction])

  defp triggers(check, source) do
    check |> issues(source, @web_file) |> Enum.map(& &1.trigger) |> Enum.sort()
  end

  defp issues(check, source, filename) do
    source
    |> SourceFile.parse(filename)
    |> check.run([])
  end
end
