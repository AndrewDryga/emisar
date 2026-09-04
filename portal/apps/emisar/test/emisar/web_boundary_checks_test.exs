defmodule Emisar.WebBoundaryChecksTest do
  @moduledoc """
  Fixture coverage for the Credo checks that keep `apps/emisar_web` an adapter:
  no nested domain calls, no changeset construction, no audit writes, no `Repo`,
  no hand-painted island containers, no hard-sliced hashes, and no unguarded
  `mount/3` subscribe.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  # Most of these checks are path-scoped, so every probe is parsed as a web file.
  @web_file "apps/emisar_web/lib/emisar_web/probe.ex"
  @live_file "apps/emisar_web/lib/emisar_web/live/probe_live.ex"

  setup_all do
    load()
  end

  describe "Emisar.Checks.WebNoNestedDomainCalls" do
    test "flags a fully qualified nested domain call" do
      source = """
      defmodule EmisarWeb.Probe do
        def packs, do: Emisar.Catalog.PublishedRegistry.list()
      end
      """

      assert triggers(nested_check(), source, @web_file) == ["Catalog.PublishedRegistry.list"]
    end

    test "flags a nested call reached through the top-level context alias" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Catalog

        def pack(id), do: Catalog.PublishedRegistry.get(id)
      end
      """

      assert triggers(nested_check(), source, @web_file) == ["Catalog.PublishedRegistry.get"]
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

      assert triggers(nested_check(), source, @web_file) == [
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

      assert triggers(nested_check(), source, @web_file) == [
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

      assert triggers(nested_check(), source, @web_file) == [
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

      assert triggers(nested_check(), source, @web_file) == [
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

      assert triggers(nested_check(), source, @web_file) == [
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

      assert triggers(nested_check(), source, @web_file) == []
    end

    test "allows the Emisar.Auth.Subject carrier, aliased or fully qualified" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Auth.Subject

        def build(user, account), do: Subject.for_user(user, account, :magic_link, [])
        def rebuild(user, account), do: Emisar.Auth.Subject.for_user(user, account, nil)
      end
      """

      assert triggers(nested_check(), source, @web_file) == []
    end

    test "does not treat EmisarWeb as Emisar" do
      source = """
      defmodule EmisarWeb.Probe do
        alias EmisarWeb.MCP.Service

        def call, do: Service.Handler.dispatch(:ping)
        def other, do: EmisarWeb.CoreComponents.Icon.render(%{})
      end
      """

      assert triggers(nested_check(), source, @web_file) == []
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

      assert triggers(changeset_check(), source, @web_file) == [
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

      assert triggers(changeset_check(), source, @web_file) == [
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

      assert triggers(changeset_check(), source, @web_file) == ["Ecto.Changeset.add_error"]
    end

    test "flags import Ecto.Changeset, plain and scoped" do
      source = """
      defmodule EmisarWeb.Probe do
        import Ecto.Changeset
        import Ecto.Changeset, only: [cast: 3]
        import Ecto.Changeset, except: [add_error: 4]
      end
      """

      assert triggers(changeset_check(), source, @web_file) == [
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

      assert triggers(changeset_check(), source, @web_file) == ["Ecto.Changeset.put_change"]
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

      assert triggers(changeset_check(), source, @web_file) == []
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

  describe "Emisar.Checks.WebNoAuditLog" do
    test "flags a hand-built Audit.Events row in the web layer" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Audit

        def record(user), do: Audit.Events.user_signed_in(user)
      end
      """

      assert [issue] = issues(audit_check(), source, @web_file)
      assert issue.check == audit_check()
      assert issue.trigger == "Audit.Events.user_signed_in"
      assert issue.line_no == 4
      assert issue.message =~ "audit is a domain concern"
    end

    test "flags every Audit write helper" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Audit

        def log(event), do: Audit.log(event)
        def log_for(user, event), do: Audit.log_for_user(user, event)
        def record(event), do: Emisar.Audit.record(event)
      end
      """

      assert triggers(audit_check(), source, @web_file) == [
               "Audit.log",
               "Audit.log_for_user",
               "Audit.record"
             ]
    end

    test "allows reads through the Audit context and a mutation via its own context" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Accounts
        alias Emisar.Audit

        def events(subject), do: Audit.list_events(subject, [])
        def sign_in(user, context), do: Accounts.record_sign_in(user, context)
      end
      """

      assert issues(audit_check(), source, @web_file) == []
    end

    test "ignores sources outside apps/emisar_web/lib" do
      source = """
      defmodule Emisar.Probe do
        def log(event), do: Audit.log(event)
      end
      """

      assert issues(audit_check(), source, "apps/emisar/lib/emisar/probe.ex") == []
    end
  end

  describe "Emisar.Checks.WebNoRepoCalls" do
    test "flags a Repo call in the web layer" do
      source = """
      defmodule EmisarWeb.Probe do
        def runbooks, do: Emisar.Repo.all(Runbook)
      end
      """

      assert [issue] = issues(repo_check(), source, @web_file)
      assert issue.check == repo_check()
      assert issue.trigger == "Repo.all"
      assert issue.line_no == 2
      assert issue.message =~ "the web calls context"
    end

    test "allows Repo structs used as documented LiveTable data types" do
      source = """
      defmodule EmisarWeb.Probe do
        alias Emisar.Repo.Paginator

        def page(%Paginator.Metadata{} = metadata), do: metadata.after
        def rows(subject), do: Emisar.Runbooks.list_runbooks(subject, [])
      end
      """

      assert issues(repo_check(), source, @web_file) == []
    end

    test "ignores sources outside apps/emisar_web/lib" do
      source = """
      defmodule Emisar.Probe do
        def runbooks, do: Emisar.Repo.all(Runbook)
      end
      """

      assert issues(repo_check(), source, "apps/emisar/lib/emisar/probe.ex") == []
    end
  end

  describe "Emisar.Checks.NoIslandContainers" do
    test "flags a container tag hand-painting a wash background plus a frame" do
      source = """
      defmodule EmisarWeb.ProbeLive do
        def render(assigns) do
          ~H\"""
          <div class="rounded-lg bg-zinc-900/60 p-4 ring-1 ring-white/[0.07]">
            <p>Naked content</p>
          </div>
          \"""
        end
      end
      """

      assert [issue] = issues(island_check(), source, @live_file)
      assert issue.check == island_check()
      assert issue.line_no == 4
      assert issue.message =~ "Hand-painted island"
    end

    test "allows naked content, a shared component, and a wash without a frame" do
      source = """
      defmodule EmisarWeb.ProbeLive do
        def render(assigns) do
          ~H\"""
          <div class="divide-y divide-zinc-800/70">
            <.code_panel id="cmd" label="Command" code={@command} />
            <div class="bg-zinc-900/60 p-4">
              <span class="bg-zinc-800 ring-1 ring-white/10">chip</span>
            </div>
          </div>
          \"""
        end
      end
      """

      assert issues(island_check(), source, @live_file) == []
    end

    test "honors the HEEx disable marker on the line above the tag" do
      source = """
      defmodule EmisarWeb.ProbeLive do
        def render(assigns) do
          ~H\"""
          <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — sanctioned recess --%>
          <div class="rounded-lg bg-zinc-900/60 p-4 ring-1 ring-white/[0.07]"></div>
          \"""
        end
      end
      """

      assert issues(island_check(), source, @live_file) == []
    end

    test "ignores web files outside live/" do
      source = """
      defmodule EmisarWeb.Probe do
        def render(assigns) do
          ~H\"""
          <div class="rounded-lg bg-zinc-900/60 p-4 ring-1 ring-white/[0.07]"></div>
          \"""
        end
      end
      """

      assert issues(island_check(), source, @web_file) == []
    end
  end

  describe "Emisar.Checks.NoHashPrefixSlice" do
    test "flags a hash sliced to a fixed prefix" do
      source = """
      defmodule EmisarWeb.Probe do
        def short(sha), do: String.slice(sha, 0, 16)
      end
      """

      assert [issue] = issues(hash_slice_check(), source, @web_file)
      assert issue.check == hash_slice_check()
      assert issue.trigger == "String.slice"
      assert issue.line_no == 2
      assert issue.message =~ "hash/id is hard-sliced"
    end

    test "flags a sliced digest read off a struct field" do
      source = """
      defmodule EmisarWeb.Probe do
        def short(version), do: String.slice(version.advertised_hash, 0, 12)
      end
      """

      assert triggers(hash_slice_check(), source, @web_file) == ["String.slice"]
    end

    test "allows the full value and a prose truncation" do
      source = """
      defmodule EmisarWeb.Probe do
        def full(sha), do: sha
        def teaser(title), do: String.slice(title, 0, 80)
      end
      """

      assert issues(hash_slice_check(), source, @web_file) == []
    end

    test "ignores a context slicing a digest for storage" do
      source = """
      defmodule Emisar.Probe do
        def short(sha), do: String.slice(sha, 0, 16)
      end
      """

      assert issues(hash_slice_check(), source, "apps/emisar/lib/emisar/probe.ex") == []
    end
  end

  describe "Emisar.Checks.SubscribeNeedsConnected" do
    test "flags a mount/3 that subscribes without a connected? guard" do
      source = """
      defmodule EmisarWeb.ProbeLive do
        def mount(_params, _session, socket) do
          Emisar.PubSub.subscribe_runs(socket.assigns.account)
          {:ok, socket}
        end
      end
      """

      assert [issue] = issues(subscribe_check(), source, @live_file)
      assert issue.check == subscribe_check()
      assert issue.trigger == "subscribe"
      assert issue.line_no == 2
      assert issue.message =~ "IL-18"
    end

    test "allows a mount guarded by connected?/1" do
      source = """
      defmodule EmisarWeb.ProbeLive do
        def mount(_params, _session, socket) do
          if connected?(socket), do: Emisar.PubSub.subscribe_runs(socket.assigns.account)
          {:ok, socket}
        end
      end
      """

      assert issues(subscribe_check(), source, @live_file) == []
    end

    test "ignores an unguarded subscribe outside mount and outside live/" do
      unguarded_mount = """
      defmodule EmisarWeb.ProbeLive do
        def mount(_params, _session, socket) do
          Emisar.PubSub.subscribe_runs(socket.assigns.account)
          {:ok, socket}
        end
      end
      """

      handle_event = """
      defmodule EmisarWeb.ProbeLive do
        def handle_event("watch", _params, socket) do
          Emisar.PubSub.subscribe_runs(socket.assigns.account)
          {:noreply, socket}
        end
      end
      """

      assert issues(subscribe_check(), unguarded_mount, @web_file) == []
      assert issues(subscribe_check(), handle_event, @live_file) == []
    end
  end

  defp nested_check, do: check("WebNoNestedDomainCalls")
  defp changeset_check, do: check("WebNoChangesetConstruction")
  defp audit_check, do: check("WebNoAuditLog")
  defp repo_check, do: check("WebNoRepoCalls")
  defp island_check, do: check("NoIslandContainers")
  defp hash_slice_check, do: check("NoHashPrefixSlice")
  defp subscribe_check, do: check("SubscribeNeedsConnected")
end
