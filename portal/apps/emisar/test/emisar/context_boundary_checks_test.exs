defmodule Emisar.ContextBoundaryChecksTest do
  @moduledoc """
  Fixture coverage for the Credo checks that keep a context the authorization
  and ownership boundary: the authorizer's fail-closed fallback, the
  `%Subject{}` requirement on public DB reads, attrs whitelisting, the crypto
  seam, cross-context reach-ins, preload smuggling, and `Ecto.Enum`.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  @authorizer "apps/emisar/lib/emisar/sprockets/authorizer.ex"
  @context "apps/emisar/lib/emisar/sprockets.ex"
  @changeset "apps/emisar/lib/emisar/sprockets/sprocket/changeset.ex"
  @query "apps/emisar/lib/emisar/sprockets/sprocket/query.ex"

  setup_all do
    load()
  end

  describe "Emisar.Checks.AuthorizerFallbackFailClosed" do
    test "flags a catch-all clause that hands back the unscoped queryable" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, _subject), do: queryable
      end
      """

      assert [issue] = issues(authorizer(), source, @authorizer)
      assert issue.check == authorizer()
      assert issue.trigger == "for_subject"
      assert issue.line_no == 2
      assert issue.message =~ "must fail closed"
    end

    test "flags an open `case` fallback on the query source" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, %Subject{account: %{id: account_id}}) do
          case query_source(queryable) do
            :sprockets -> Sprocket.Query.by_account_id(queryable, account_id)
            _source -> queryable
          end
        end
      end
      """

      assert triggers(authorizer(), source, @authorizer) == ["for_subject"]
    end

    test "flags a fail-open clause behind a guard" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, _subject) when is_atom(queryable), do: queryable
      end
      """

      assert [issue] = issues(authorizer(), source, @authorizer)
      assert issue.line_no == 2
    end

    test "flags an open `case` fallback inside a guarded clause" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, %Subject{account: %{id: account_id}} = subject)
            when is_map(subject) do
          case query_source(queryable) do
            :sprockets -> Sprocket.Query.by_account_id(queryable, account_id)
            _source -> queryable
          end
        end
      end
      """

      assert triggers(authorizer(), source, @authorizer) == ["for_subject"]
    end

    test "flags a fallback that an unrelated later clause used to mask" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, %Subject{} = subject) do
          case subject.actor do
            %User{} ->
              case query_source(queryable) do
                :sprockets -> Sprocket.Query.by_account_id(queryable, subject.account.id)
                _source -> queryable
              end

            %Runner{} ->
              case query_source(queryable) do
                :sprockets -> Sprocket.Query.by_runner_id(queryable, subject.actor.id)
                :gadgets -> queryable
              end
          end
        end
      end
      """

      assert triggers(authorizer(), source, @authorizer) == ["for_subject"]
    end

    test "flags a `cond` whose true branch returns the queryable" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, %Subject{account: %{id: account_id}} = subject) do
          cond do
            Subject.staff?(subject) -> Sprocket.Query.none(queryable)
            is_binary(account_id) -> Sprocket.Query.by_account_id(queryable, account_id)
            true -> queryable
          end
        end
      end
      """

      assert triggers(authorizer(), source, @authorizer) == ["for_subject"]
    end

    test "allows a guarded dispatch whose every fallback goes through Query.none/1" do
      source = """
      defmodule Emisar.Sprockets.Authorizer do
        def for_subject(queryable, %Subject{account: %{id: account_id}} = subject)
            when is_map(subject) do
          case query_source(queryable) do
            :sprockets -> Sprocket.Query.by_account_id(queryable, account_id)
            _source -> Sprocket.Query.none(queryable)
          end
        end

        def for_subject(queryable, _subject), do: Sprocket.Query.none(queryable)
      end
      """

      assert issues(authorizer(), source, @authorizer) == []
    end

    test "ignores the account-less Auth authorizer" do
      source = """
      defmodule Emisar.Auth.Authorizer do
        def for_subject(queryable, _subject), do: queryable
      end
      """

      assert issues(authorizer(), source, "apps/emisar/lib/emisar/auth/authorizer.ex") == []
    end
  end

  describe "Emisar.Checks.ContextPublicFnSubject" do
    test "flags a public context read that reaches Repo without a subject" do
      source = """
      defmodule Emisar.Sprockets do
        def list_sprockets, do: Repo.list(Sprocket.Query.all())
      end
      """

      assert [issue] = issues(public_fn_subject(), source, @context)
      assert issue.check == public_fn_subject()
      assert issue.trigger == "list_sprockets"
      assert issue.line_no == 2
      assert issue.message =~ "IL-3"
    end

    test "allows a gated read, a declared internal helper, a pre-auth path, and a pure builder" do
      source = """
      defmodule Emisar.Sprockets do
        def list_sprockets(%Subject{} = subject) do
          Sprocket.Query.all() |> Authorizer.for_subject(subject) |> Repo.list()
        end

        @doc "Internal — the runner socket authorized the connection already."
        def advertise(runner_id), do: Repo.list(Sprocket.Query.by_runner_id(runner_id))

        @doc false
        def sweep_expired, do: Repo.delete_all(Sprocket.Query.expired())

        def register(attrs, %RequestContext{} = context) do
          Repo.insert(Sprocket.Changeset.create(attrs, context))
        end

        def change_sprocket(sprocket, attrs), do: Sprocket.Changeset.update(sprocket, attrs)
      end
      """

      assert issues(public_fn_subject(), source, @context) == []
    end

    test "ignores infra modules and a context's satellites" do
      source = """
      defmodule Emisar.Probe do
        def list_sprockets, do: Repo.list(Sprocket.Query.all())
      end
      """

      schema = "apps/emisar/lib/emisar/sprockets/sprocket.ex"

      assert issues(public_fn_subject(), source, "apps/emisar/lib/emisar/repo.ex") == []
      assert issues(public_fn_subject(), source, schema) == []
    end
  end

  describe "Emisar.Checks.ContextNoMapTakeDrop" do
    test "flags Map.take/Map.drop pre-filtering the input attrs" do
      source = """
      defmodule Emisar.Sprockets do
        def update(sprocket, attrs), do: Sprocket.Changeset.update(sprocket, Map.take(attrs, [:name]))
        def scrub(params), do: Map.drop(params, [:id])
      end
      """

      assert triggers(map_take_drop(), source, @context) == [
               "Map.drop(params, …)",
               "Map.take(attrs, …)"
             ]

      assert [issue | _] = issues(map_take_drop(), source, @context)
      assert issue.check == map_take_drop()
      assert issue.message =~ "cast/3"
    end

    test "allows Map.take/drop on a payload that is not input attrs" do
      source = """
      defmodule Emisar.Sprockets do
        def summarize(payload), do: Map.take(payload, [:status])
        def redact(config), do: Map.drop(config, [:secret])
      end
      """

      assert issues(map_take_drop(), source, @context) == []
    end
  end

  describe "Emisar.Checks.ContextCryptoBoundary" do
    test "flags inline :crypto and Base.url_encode64 in a context" do
      source = """
      defmodule Emisar.Sprockets do
        def mint, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      end
      """

      assert triggers(crypto_boundary(), source, @context) == [
               ":crypto.strong_rand_bytes",
               "Base.url_encode64"
             ]

      assert [issue | _] = issues(crypto_boundary(), source, @context)
      assert issue.check == crypto_boundary()
      assert issue.message =~ "Emisar.Crypto"
    end

    test "allows the named Emisar.Crypto functions and non-secret encoding" do
      source = """
      defmodule Emisar.Sprockets do
        def mint, do: Emisar.Crypto.mint_token("wgt")
        def fingerprint(bytes), do: Base.encode16(bytes, case: :lower)
      end
      """

      assert issues(crypto_boundary(), source, @context) == []
    end

    test "ignores Emisar.Crypto itself" do
      source = """
      defmodule Emisar.Crypto do
        def random_bytes(size), do: :crypto.strong_rand_bytes(size)
      end
      """

      assert issues(crypto_boundary(), source, "apps/emisar/lib/emisar/crypto.ex") == []
    end
  end

  describe "Emisar.Checks.CrossContextDeepAlias" do
    test "flags a deep alias into another context, single and grouped" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.Accounts.{Account, Membership}
        alias Emisar.Runs.ActionRun
      end
      """

      assert triggers(deep_alias(), source, @context) == ["Emisar.Accounts", "Emisar.Runs"]
      assert [issue | _] = issues(deep_alias(), source, @context)
      assert issue.check == deep_alias()
      assert issue.message =~ "cross-context deep alias"
    end

    test "allows the top-level alias, own submodules, Auth.Subject, and Repo infra" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.Auth.Subject
        alias Emisar.Repo.Paginator
        alias Emisar.Runs
        alias Emisar.Sprockets.Sprocket
      end
      """

      assert issues(deep_alias(), source, @context) == []
    end
  end

  describe "Emisar.Checks.CrossContextDeepCall" do
    test "flags a call into a sibling context's Query or Changeset" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.Runs

        def peek(id), do: Runs.ActionRun.Query.by_id(id)
        def build(attrs), do: Emisar.Accounts.Account.Changeset.create(attrs)
      end
      """

      assert triggers(deep_call(), source, @context) == ["Account.Changeset", "ActionRun.Query"]
      assert [issue | _] = issues(deep_call(), source, @context)
      assert issue.check == deep_call()
      assert issue.message =~ "sibling context"
    end

    test "allows a sibling's public API, the context's own Query, and Repo helpers" do
      source = """
      defmodule Emisar.Sprockets do
        alias Emisar.Runs

        def peek(id), do: Runs.peek_run_by_id(id)
        def own(id), do: Sprocket.Query.by_id(id)
        def slug(changeset), do: Emisar.Repo.Changeset.put_slug(changeset, :name)
      end
      """

      assert issues(deep_call(), source, @context) == []
    end

    test "ignores a Query module composing a sibling's Query in a join" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Query do
        use Emisar, :query
        alias Emisar.Runs

        def with_live_runs(queryable), do: join(queryable, :inner, [w], Runs.ActionRun.Query.live())
      end
      """

      assert issues(deep_call(), source, @query) == []
    end
  end

  describe "Emisar.Checks.NoPreloadInRepoOpts" do
    test "flags a preload put into Repo opts and a literal preload: argument" do
      source = """
      defmodule Emisar.Sprockets do
        def list(opts), do: Repo.list(Sprocket.Query.all(), Keyword.put(opts, :preload, [:account]))
        def fetch(id), do: Repo.fetch(Sprocket.Query.by_id(id), preload: [:account])
      end
      """

      assert triggers(preload_opts(), source, @context) == [
               "Keyword.put(:preload)",
               "Repo.fetch(preload:)"
             ]

      assert [issue | _] = issues(preload_opts(), source, @context)
      assert issue.check == preload_opts()
      assert issue.message =~ "with_preloaded_"
    end

    test "allows popping the caller's preload and mapping it to Query helpers" do
      source = """
      defmodule Emisar.Sprockets do
        def list(opts) do
          {preload, opts} = Keyword.pop(opts, :preload, [])
          Sprocket.Query.all() |> apply_preloads(preload) |> Repo.list(opts)
        end
      end
      """

      assert issues(preload_opts(), source, @context) == []
    end
  end

  describe "Emisar.Checks.EnumOverValidateInclusion" do
    test "flags validate_inclusion over a literal list" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Changeset do
        use Emisar, :changeset

        def create(attrs) do
          changeset = cast(%Sprocket{}, attrs, [:kind])
          validate_inclusion(changeset, :kind, ["alpha", "beta"])
        end
      end
      """

      assert [issue] = issues(enum_over_inclusion(), source, @changeset)
      assert issue.check == enum_over_inclusion()
      assert issue.trigger == "validate_inclusion"
      assert issue.line_no == 6
      assert issue.message =~ "Ecto.Enum"
    end

    test "flags the qualified form and a module-attribute value set" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Changeset do
        use Emisar, :changeset

        @kinds ~w(alpha beta)

        def create(changeset) do
          Ecto.Changeset.validate_inclusion(changeset, :kind, @kinds)
        end
      end
      """

      assert triggers(enum_over_inclusion(), source, @changeset) == ["validate_inclusion"]
    end

    test "flags the piped spelling at both arities and names the right field" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Changeset do
        use Emisar, :changeset

        @tiers ~w(gold silver)

        def create(changeset) do
          changeset
          |> validate_inclusion(:kind, ["alpha", "beta"])
          |> validate_inclusion(:mode, ["fast", "slow"], message: "unsupported")
          |> Ecto.Changeset.validate_inclusion(:tier, @tiers)
          |> validate_inclusion(:shape, ~w(round square))
        end
      end
      """

      flagged =
        enum_over_inclusion() |> issues(source, @changeset) |> Enum.sort_by(& &1.line_no)

      assert [kind, mode, tier, shape] = flagged
      assert kind.line_no == 8
      assert kind.message =~ ":kind"
      assert mode.line_no == 9
      assert mode.message =~ ":mode"
      assert tier.line_no == 10
      assert tier.message =~ ":tier"
      assert shape.line_no == 11
      assert shape.message =~ ":shape"
    end

    test "allows a runtime value set, options and all" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Changeset do
        use Emisar, :changeset

        def create(changeset, allowed_kinds) do
          changeset
          |> validate_inclusion(:kind, allowed_kinds)
          |> validate_inclusion(:mode, modes(), message: "unsupported")
        end
      end
      """

      assert issues(enum_over_inclusion(), source, @changeset) == []
    end

    test "ignores a module that is not a changeset" do
      source = """
      defmodule Emisar.Sprockets do
        def create(changeset), do: validate_inclusion(changeset, :kind, ["alpha"])
      end
      """

      assert issues(enum_over_inclusion(), source, @context) == []
    end
  end

  defp authorizer, do: check("AuthorizerFallbackFailClosed")
  defp public_fn_subject, do: check("ContextPublicFnSubject")
  defp map_take_drop, do: check("ContextNoMapTakeDrop")
  defp crypto_boundary, do: check("ContextCryptoBoundary")
  defp deep_alias, do: check("CrossContextDeepAlias")
  defp deep_call, do: check("CrossContextDeepCall")
  defp preload_opts, do: check("NoPreloadInRepoOpts")
  defp enum_over_inclusion, do: check("EnumOverValidateInclusion")
end
