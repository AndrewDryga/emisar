defmodule Emisar.RuntimeSafetyChecksTest do
  @moduledoc """
  Fixture coverage for the Credo checks that guard runtime behaviour: global
  app-env mutation, the process dictionary, unsafe deserialization, silent
  `match?` value tests, count-vs-exists reads, timestamp truncation, the vendor
  wrapper seam, and the two PubSub publishing rules.

  Each check gets a probe it MUST flag and a compliant probe it MUST NOT.
  """
  use ExUnit.Case, async: true
  import Emisar.CredoCheckProbe

  @context "apps/emisar/lib/emisar/sprockets.ex"
  @changeset "apps/emisar/lib/emisar/sprockets/sprocket/changeset.ex"
  @test_file "apps/emisar/test/emisar/sprockets_test.exs"

  setup_all do
    load()
  end

  describe "Emisar.Checks.NoApplicationPutEnv" do
    test "flags Application.put_env" do
      source = """
      defmodule Emisar.Sprockets do
        def enable, do: Application.put_env(:emisar, :feature, true)
      end
      """

      assert [issue] = issues(put_env(), source, @context)
      assert issue.check == put_env()
      assert issue.trigger == "Application.put_env"
      assert issue.line_no == 2
      assert issue.message =~ "Emisar.Config.put_override/3"
    end

    test "flags delete_env and put_all_env, in lib and in test" do
      source = """
      defmodule Emisar.Sprockets do
        def disable, do: Application.delete_env(:emisar, :feature)
        def load(all), do: Application.put_all_env(all)
      end
      """

      assert triggers(put_env(), source, @context) == [
               "Application.delete_env",
               "Application.put_all_env"
             ]

      assert triggers(put_env(), source, @test_file) == [
               "Application.delete_env",
               "Application.put_all_env"
             ]
    end

    test "allows reading app env and the test-scoped Emisar.Config override" do
      source = """
      defmodule Emisar.Sprockets do
        def feature?, do: Emisar.Config.get_env(:emisar, :feature, false)
        def override, do: Emisar.Config.put_override(:emisar, :feature, true)
        def endpoint, do: Application.get_env(:emisar, :endpoint)
      end
      """

      assert issues(put_env(), source, @context) == []
    end

    test "ignores config files, where setting app env is the whole point" do
      source = """
      import Config
      config :emisar, :feature, true
      Application.put_env(:emisar, :feature, true)
      """

      assert issues(put_env(), source, "config/runtime.exs") == []
    end
  end

  describe "Emisar.Checks.NoProcessDictionary" do
    test "flags Process.put stashing ambient request state" do
      source = """
      defmodule Emisar.Sprockets do
        def remember(ip), do: Process.put(:request_ip, ip)
      end
      """

      assert [issue] = issues(process_dictionary(), source, @context)
      assert issue.check == process_dictionary()
      assert issue.trigger == "Process.put"
      assert issue.line_no == 2
      assert issue.message =~ "RequestContext"
    end

    test "allows threading the request context and reading the dictionary" do
      source = """
      defmodule Emisar.Sprockets do
        def ip(%Subject{context: %RequestContext{ip_address: ip}}), do: ip
        def caller, do: Process.get(:"$callers")
      end
      """

      assert issues(process_dictionary(), source, @context) == []
    end

    test "ignores test sources" do
      source = """
      defmodule Emisar.SprocketsTest do
        def stash(ip), do: Process.put(:request_ip, ip)
      end
      """

      assert issues(process_dictionary(), source, @test_file) == []
    end
  end

  describe "Emisar.Checks.NoUnsafeDeserialization" do
    test "flags :erlang.binary_to_term even with :safe" do
      source = """
      defmodule Emisar.Sprockets do
        def decode(cursor), do: :erlang.binary_to_term(cursor, [:safe])
      end
      """

      assert [issue] = issues(unsafe_deserialization(), source, @context)
      assert issue.check == unsafe_deserialization()
      assert issue.trigger == ":erlang.binary_to_term"
      assert issue.line_no == 2
      assert issue.message =~ "size bound"
    end

    test "flags the non-executable variant and runtime code evaluation" do
      source = """
      defmodule Emisar.Sprockets do
        def decode(cursor), do: Plug.Crypto.non_executable_binary_to_term(cursor, [:safe])
        def evaluate(code), do: Code.eval_string(code)
        def evaluate_quoted(ast), do: Code.eval_quoted(ast)
      end
      """

      assert triggers(unsafe_deserialization(), source, @context) == [
               "Code.eval_quoted",
               "Code.eval_string",
               "Plug.Crypto.non_executable_binary_to_term"
             ]
    end

    test "allows a bounded Base64 + Jason decode" do
      source = """
      defmodule Emisar.Sprockets do
        def decode(cursor) do
          with {:ok, json} <- Base.url_decode64(cursor, padding: false),
               true <- byte_size(json) <= 512 do
            Jason.decode(json)
          end
        end
      end
      """

      assert issues(unsafe_deserialization(), source, @context) == []
    end
  end

  describe "Emisar.Checks.MatchOnMapFieldValue" do
    test "flags a match? testing a field value through a bare map pattern" do
      source = """
      defmodule Emisar.Sprockets do
        def sso_required?, do: match?({:ok, %{require_sso: true}}, fetch_settings())
      end
      """

      assert [issue] = issues(match_on_value(), source, @context)
      assert issue.check == match_on_value()
      assert issue.trigger == "match?"
      assert issue.line_no == 2
      assert issue.message =~ "silently always-false"
    end

    test "allows shape tests and a struct pattern the compiler checks" do
      source = """
      defmodule Emisar.Sprockets do
        def ok?(result), do: match?({:ok, _}, result)
        def user?(actor), do: match?(%User{}, actor)
        def settings?(result), do: match?({:ok, %{}}, result)
        def active?(execution), do: match?(%RunbookExecution{status: :active}, execution)
      end
      """

      assert issues(match_on_value(), source, @context) == []
    end
  end

  describe "Emisar.Checks.RepoExistsOverCount" do
    test "flags a count compared against zero" do
      source = """
      defmodule Emisar.Sprockets do
        def any?(queryable), do: Repo.aggregate(queryable, :count) > 0
      end
      """

      assert [issue] = issues(exists_over_count(), source, @context)
      assert issue.check == exists_over_count()
      assert issue.trigger == "Repo.aggregate"
      assert issue.line_no == 2
      assert issue.message =~ "Repo.exists?"
    end

    test "flags the reversed and the piped spellings" do
      source = """
      defmodule Emisar.Sprockets do
        def none?(queryable), do: 0 == Emisar.Repo.aggregate(queryable, :count)
        def any?(queryable), do: queryable |> Repo.aggregate(:count) > 0
      end
      """

      assert triggers(exists_over_count(), source, @context) == [
               "Repo.aggregate",
               "Repo.aggregate"
             ]
    end

    test "allows Repo.exists? and a count compared against a real threshold" do
      source = """
      defmodule Emisar.Sprockets do
        def any?(queryable), do: Repo.exists?(queryable)
        def crowded?(queryable), do: Repo.aggregate(queryable, :count) > 5
      end
      """

      assert issues(exists_over_count(), source, @context) == []
    end
  end

  describe "Emisar.Checks.NoDateTimeTruncate" do
    test "flags truncating utc_now, piped and direct" do
      piped = """
      defmodule Emisar.Sprockets do
        def now, do: DateTime.utc_now() |> DateTime.truncate(:second)
      end
      """

      direct = """
      defmodule Emisar.Sprockets do
        def now, do: DateTime.truncate(DateTime.utc_now(), :second)
      end
      """

      assert [issue] = issues(datetime_truncate(), piped, @context)
      assert issue.check == datetime_truncate()
      assert issue.trigger == "DateTime.truncate"
      assert issue.line_no == 2
      assert issue.message =~ ":utc_datetime_usec"

      assert triggers(datetime_truncate(), direct, @context) == ["DateTime.truncate"]
    end

    test "flags any truncate inside a changeset module" do
      source = """
      defmodule Emisar.Sprockets.Sprocket.Changeset do
        use Emisar, :changeset

        def delete(sprocket), do: change(sprocket, deleted_at: DateTime.truncate(stamp(), :second))
      end
      """

      assert triggers(datetime_truncate(), source, @changeset) == ["DateTime.truncate"]
    end

    test "allows utc_now on its own and a truncate outside a changeset" do
      source = """
      defmodule Emisar.Sprockets do
        def now, do: DateTime.utc_now()
        def coarse(row), do: DateTime.truncate(row.inserted_at, :second)
      end
      """

      assert issues(datetime_truncate(), source, @context) == []
    end
  end

  describe "Emisar.Checks.VendorViaWrapper" do
    test "flags a raw HTTP client call outside a wrapper" do
      source = """
      defmodule Emisar.Sprockets do
        def fetch(request), do: Finch.request(request, Emisar.Finch)
      end
      """

      assert [issue] = issues(vendor_wrapper(), source, @context)
      assert issue.check == vendor_wrapper()
      assert issue.trigger == "Finch.request"
      assert issue.line_no == 2
      assert issue.message =~ "IL-19"
    end

    test "flags every known raw client" do
      source = """
      defmodule Emisar.Sprockets do
        def a(url), do: Req.get!(url)
        def b(url), do: HTTPoison.get(url)
        def c(url), do: Tesla.get(url)
      end
      """

      assert triggers(vendor_wrapper(), source, @context) == [
               "HTTPoison.get",
               "Req.get!",
               "Tesla.get"
             ]
    end

    test "allows the wrapper module itself, the Finch pool child spec, and a wrapped call" do
      raw = """
      defmodule Emisar.Billing.PaddleClient.Live do
        def fetch(request), do: Finch.request(request, Emisar.Finch)
      end
      """

      wrapped = """
      defmodule Emisar.Sprockets do
        def charge(account), do: Emisar.Billing.PaddleClient.charge(account)
      end
      """

      assert issues(vendor_wrapper(), raw, "apps/emisar/lib/emisar/billing/paddle_client.ex") ==
               []

      assert issues(vendor_wrapper(), raw, "apps/emisar/lib/emisar/application.ex") == []
      assert issues(vendor_wrapper(), wrapped, @context) == []
    end
  end

  describe "Emisar.Checks.BroadcastEventAsData" do
    test "flags an event name passed to a broadcast helper as data" do
      source = """
      defmodule Emisar.ApiKeys do
        def revoke(key), do: broadcast_change(key, "auth_key.revoked")
      end
      """

      assert [issue] = issues(event_as_data(), source, "apps/emisar/lib/emisar/api_keys.ex")
      assert issue.check == event_as_data()
      assert issue.trigger == "broadcast_change"
      assert issue.line_no == 2
      assert issue.message =~ "dedicated broadcast_"
    end

    test "allows a per-event broadcast function owning its literal topic" do
      source = """
      defmodule Emisar.ApiKeys do
        def revoke(key), do: broadcast_auth_key_revoked(key)

        defp broadcast_auth_key_revoked(key) do
          Emisar.PubSub.broadcast(topic(key), {:auth_key_revoked, key})
        end
      end
      """

      assert issues(event_as_data(), source, "apps/emisar/lib/emisar/api_keys.ex") == []
    end

    test "ignores the web layer" do
      source = """
      defmodule EmisarWeb.Probe do
        def revoke(key), do: broadcast_change(key, "auth_key.revoked")
      end
      """

      assert issues(event_as_data(), source, "apps/emisar_web/lib/emisar_web/probe.ex") == []
    end
  end

  describe "Emisar.Checks.InlineBroadcast" do
    test "flags a PubSub.broadcast at a mutation site" do
      source = """
      defmodule Emisar.ApiKeys do
        def revoke(key) do
          Emisar.PubSub.broadcast(topic(key), {:auth_key_revoked, key})
        end
      end
      """

      assert [issue] = issues(inline_broadcast(), source, "apps/emisar/lib/emisar/api_keys.ex")
      assert issue.check == inline_broadcast()
      assert issue.trigger == "PubSub.broadcast"
      assert issue.line_no == 3
      assert issue.message =~ "named per-event broadcast_"
    end

    test "allows a publish that lives inside its own broadcast_* function" do
      source = """
      defmodule Emisar.ApiKeys do
        def revoke(key), do: broadcast_auth_key_revoked(key)

        defp broadcast_auth_key_revoked(key) do
          Emisar.PubSub.broadcast(topic(key), {:auth_key_revoked, key})
        end
      end
      """

      assert issues(inline_broadcast(), source, "apps/emisar/lib/emisar/api_keys.ex") == []
    end

    test "ignores the PubSub module itself" do
      source = """
      defmodule Emisar.PubSub do
        def publish(topic, message), do: Emisar.PubSub.broadcast(topic, message)
      end
      """

      assert issues(inline_broadcast(), source, "apps/emisar/lib/emisar/pubsub.ex") == []
    end
  end

  defp put_env, do: check("NoApplicationPutEnv")
  defp process_dictionary, do: check("NoProcessDictionary")
  defp unsafe_deserialization, do: check("NoUnsafeDeserialization")
  defp match_on_value, do: check("MatchOnMapFieldValue")
  defp exists_over_count, do: check("RepoExistsOverCount")
  defp datetime_truncate, do: check("NoDateTimeTruncate")
  defp vendor_wrapper, do: check("VendorViaWrapper")
  defp event_as_data, do: check("BroadcastEventAsData")
  defp inline_broadcast, do: check("InlineBroadcast")
end
