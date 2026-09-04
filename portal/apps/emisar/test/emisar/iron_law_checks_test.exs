defmodule Emisar.IronLawChecksTest do
  @moduledoc """
  Fixture coverage for the Credo checks that enforce the layered-context Iron
  Laws: IL-1, IL-2, IL-6, IL-7, IL-8, and IL-12.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT, so a
  silent AST regression fails here instead of quietly waving the next violation
  through.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  @context "apps/emisar/lib/emisar/runbooks.ex"
  @query "apps/emisar/lib/emisar/runbooks/runbook/query.ex"
  @changeset "apps/emisar/lib/emisar/runbooks/runbook/changeset.ex"
  @schema "apps/emisar/lib/emisar/runbooks/runbook.ex"
  @migration "apps/emisar/priv/repo/migrations/20260101000000_create_invoices.exs"

  setup_all do
    load()
  end

  describe "Emisar.Checks.IL01NoInlineEctoDsl" do
    test "flags a literal import Ecto.Query in a context" do
      source = """
      defmodule Emisar.Runbooks do
        import Ecto.Query
      end
      """

      assert [issue] = issues(il01(), source, @context)
      assert issue.check == il01()
      assert issue.trigger == "import Ecto.Query"
      assert issue.line_no == 2
      assert issue.message =~ "IL-1"
    end

    test "flags a qualified Ecto.Query call alongside a scoped import" do
      source = """
      defmodule Emisar.Runbooks do
        import Ecto.Query, only: [from: 2]

        def recent(account_id) do
          Ecto.Query.from(r in "runbooks", where: r.account_id == ^account_id)
        end
      end
      """

      assert triggers(il01(), source, @context) == ["Ecto.Query.from", "import Ecto.Query"]
    end

    test "allows a Query module taking the DSL through use Emisar, :query" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Query do
        use Emisar, :query

        def by_account_id(queryable \\\\ all(), account_id) do
          where(queryable, [runbooks: r], r.account_id == ^account_id)
        end
      end
      """

      assert issues(il01(), source, @query) == []
    end

    test "ignores the Repo machinery that owns the DSL" do
      source = """
      defmodule Emisar.Repo.Paginator do
        import Ecto.Query
      end
      """

      assert issues(il01(), source, "apps/emisar/lib/emisar/repo/paginator.ex") == []
      assert issues(il01(), source, "apps/emisar/lib/emisar.ex") == []
    end
  end

  describe "Emisar.Checks.IL02NoRepoGet" do
    test "flags Repo.get" do
      source = """
      defmodule Emisar.Runbooks do
        def one(id), do: Repo.get(Runbook, id)
      end
      """

      assert [issue] = issues(il02(), source, @context)
      assert issue.check == il02()
      assert issue.trigger == "Repo.get"
      assert issue.line_no == 2
      assert issue.message =~ "IL-2"
    end

    test "flags get!, get_by, and the fully qualified form" do
      source = """
      defmodule Emisar.Runbooks do
        def one!(id), do: Emisar.Repo.get!(Runbook, id)
        def by_slug(slug), do: Repo.get_by(Runbook, slug: slug)
      end
      """

      assert triggers(il02(), source, @context) == ["Repo.get!", "Repo.get_by"]
    end

    test "allows a Query-module lookup read through Repo.fetch" do
      source = """
      defmodule Emisar.Runbooks do
        def fetch(id, subject) do
          Runbook.Query.by_id(id) |> Authorizer.for_subject(subject) |> Repo.fetch()
        end

        def label(attrs), do: Map.get(attrs, :label)
      end
      """

      assert issues(il02(), source, @context) == []
    end

    test "ignores Repo's own implementation" do
      source = """
      defmodule Emisar.Repo do
        def peek(schema, id), do: get(schema, id)
      end
      """

      assert issues(il02(), source, "apps/emisar/lib/emisar/repo.ex") == []
    end
  end

  describe "Emisar.Checks.IL06QueryModulePure" do
    test "flags a Repo call inside a Query module" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Query do
        use Emisar, :query

        def load(queryable), do: Repo.all(queryable)
      end
      """

      assert [issue] = issues(il06(), source, @query)
      assert issue.check == il06()
      assert issue.trigger == "Repo.all"
      assert issue.line_no == 4
      assert issue.message =~ "IL-6"
    end

    test "allows a grouped Emisar.Repo alias, which is not a Repo call" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Query do
        use Emisar, :query
        alias Emisar.Repo.{Filter, Paginator}

        def all, do: from(r in Runbook, as: :runbooks)
      end
      """

      assert issues(il06(), source, @query) == []
    end

    test "ignores a Repo call outside a Query module" do
      source = """
      defmodule Emisar.Runbooks do
        def load(queryable), do: Repo.all(queryable)
      end
      """

      assert issues(il06(), source, @context) == []
    end
  end

  describe "Emisar.Checks.IL07SchemaFieldsOnly" do
    test "flags a changeset builder and its cast/validate pipeline" do
      source = """
      defmodule Emisar.Runbooks.Runbook do
        use Emisar, :schema

        schema "runbooks" do
          field :name, :string
        end

        def changeset(runbook, attrs) do
          runbook |> cast(attrs, [:name]) |> validate_required([:name])
        end
      end
      """

      assert triggers(il07(), source, @schema) == ["cast", "def changeset", "validate_required"]
      assert [issue | _] = issues(il07(), source, @schema)
      assert issue.check == il07()
      assert issue.message =~ "IL-7"
    end

    test "allows fields, associations, and a pure struct helper" do
      source = """
      defmodule Emisar.Runbooks.Runbook do
        use Emisar, :schema

        schema "runbooks" do
          field :name, :string
          belongs_to :account, Emisar.Accounts.Account
          timestamps()
        end

        def live?(%__MODULE__{published_at: nil}), do: false
        def live?(%__MODULE__{}), do: true
      end
      """

      assert issues(il07(), source, @schema) == []
    end

    test "ignores a module that is not a schema" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Changeset do
        use Emisar, :changeset

        def create(attrs), do: %Runbook{} |> cast(attrs, [:name]) |> validate_required([:name])
      end
      """

      assert issues(il07(), source, @changeset) == []
    end
  end

  describe "Emisar.Checks.IL08ChangesetPure" do
    test "flags a Repo call inside a Changeset module" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Changeset do
        use Emisar, :changeset

        def create(attrs), do: Repo.insert(cast(%Runbook{}, attrs, [:name]))
      end
      """

      assert [issue] = issues(il08(), source, @changeset)
      assert issue.check == il08()
      assert issue.trigger == "Repo.insert"
      assert issue.line_no == 4
      assert issue.message =~ "IL-8"
    end

    test "allows the shared Emisar.Repo.Changeset helpers" do
      source = """
      defmodule Emisar.Runbooks.Runbook.Changeset do
        use Emisar, :changeset

        def create(attrs) do
          %Runbook{}
          |> cast(attrs, [:name])
          |> Emisar.Repo.Changeset.put_slug(:name)
        end
      end
      """

      assert issues(il08(), source, @changeset) == []
    end

    test "ignores the Repo's own changeset helpers" do
      source = """
      defmodule Emisar.Repo.Changeset do
        def put_slug(changeset, field), do: Repo.reload(changeset, field)
      end
      """

      assert issues(il08(), source, "apps/emisar/lib/emisar/repo/changeset.ex") == []
    end
  end

  describe "Emisar.Checks.IL12NoFloatMoney" do
    test "flags a money-named :float schema field" do
      source = """
      defmodule Emisar.Billing.Invoice do
        use Emisar, :schema

        schema "invoices" do
          field :amount_due, :float
        end
      end
      """

      assert [issue] = issues(il12(), source, "apps/emisar/lib/emisar/billing/invoice.ex")
      assert issue.check == il12()
      assert issue.trigger == "field :amount_due"
      assert issue.line_no == 5
      assert issue.message =~ "IL-12"
    end

    test "flags a money-named :float migration column and leaves other names alone" do
      source = """
      defmodule Emisar.Repo.Migrations.CreateInvoices do
        def change do
          create table(:invoices) do
            add :price, :float
            add :tax_rate, :float
            add :latency, :float
          end
        end
      end
      """

      assert triggers(il12(), source, @migration) == ["add :price", "add :tax_rate"]
    end

    test "allows :decimal and integer cents" do
      source = """
      defmodule Emisar.Billing.Invoice do
        use Emisar, :schema

        schema "invoices" do
          field :amount_cents, :integer
          field :tax_rate, :decimal
        end
      end
      """

      assert issues(il12(), source, "apps/emisar/lib/emisar/billing/invoice.ex") == []
    end
  end

  defp il01, do: check("IL01NoInlineEctoDsl")
  defp il02, do: check("IL02NoRepoGet")
  defp il06, do: check("IL06QueryModulePure")
  defp il07, do: check("IL07SchemaFieldsOnly")
  defp il08, do: check("IL08ChangesetPure")
  defp il12, do: check("IL12NoFloatMoney")
end
