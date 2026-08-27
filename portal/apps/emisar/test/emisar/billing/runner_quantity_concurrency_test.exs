defmodule Emisar.Billing.RunnerQuantityConcurrencyTest.PaddleClient do
  @behaviour Emisar.Billing.PaddleClient
  alias Emisar.Config

  @impl true
  def retrieve_subscription(id) do
    send(Config.fetch_env!(:emisar, :quantity_race_parent), {:quantity_retrieve, self(), id})

    receive do
      :release_quantity_retrieve -> :ok
    end

    {:ok, Agent.get(Config.fetch_env!(:emisar, :quantity_race_agent), & &1)}
  end

  @impl true
  def update_subscription(id, attrs) do
    send(Config.fetch_env!(:emisar, :quantity_race_parent), {:quantity_update, self(), id, attrs})
    agent = Config.fetch_env!(:emisar, :quantity_race_agent)

    updated =
      Agent.get_and_update(agent, fn remote ->
        quantities = Map.new(attrs["items"], &{&1["price_id"], &1["quantity"]})

        items =
          Enum.map(remote["items"], fn item ->
            price_id = get_in(item, ["price", "id"])
            put_in(item, ["quantity"], Map.fetch!(quantities, price_id))
          end)

        updated =
          remote
          |> Map.put("items", items)
          |> Map.put("updated_at", "2026-08-26T10:01:00.000000Z")

        {updated, updated}
      end)

    {:ok, updated}
  end

  @impl true
  defdelegate create_customer(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate update_customer(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_customers(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate create_checkout_session(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate bind_checkout_transaction(id, binding), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate create_billing_portal_session(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate retrieve_transaction(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_subscriptions(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate cancel_subscription(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_products(), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate list_transactions(attrs), to: Emisar.Billing.PaddleClient.Stub
  @impl true
  defdelegate get_transaction_invoice(id), to: Emisar.Billing.PaddleClient.Stub
  @impl true

  defdelegate construct_webhook_event(payload, signature, secret),
    to: Emisar.Billing.PaddleClient.Stub
end

defmodule Emisar.Billing.RunnerQuantityConcurrencyTest do
  use Emisar.ConcurrencyCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Emisar.Accounts.Account
  alias Emisar.{Billing, Fixtures, Repo, Runners}
  alias Emisar.Billing.RunnerQuantityConcurrencyTest.PaddleClient

  @moduletag timeout: 60_000

  test "a runner transition blocked behind convergence leaves a fresh dirty marker" do
    unboxed_quantity(fn state ->
      parent = self()
      worker = unboxed_task(fn -> Billing.reconcile_runner_quantity(state.subscription.id) end)

      try do
        assert_receive {:quantity_retrieve, worker_pid, "sub_quantity_transition"}, 5_000

        transition =
          unboxed_task(fn ->
            send(parent, {:transition_started, backend_pid()})
            Runners.disable_runner(state.runner, state.subject)
          end)

        try do
          assert_receive {:transition_started, transition_backend}, 5_000
          await_blocked(transition_backend)

          send(worker_pid, :release_quantity_retrieve)
          assert Task.await(worker, 30_000) == {:ok, :converged}
          assert {:ok, _disabled} = Task.await(transition, 30_000)

          assert %DateTime{} =
                   Repo.reload!(state.subscription).runner_quantity_sync_requested_at
        after
          stop_tasks([transition])
        end
      after
        send(worker.pid, :release_quantity_retrieve)
        stop_tasks([worker])
      end
    end)
  end

  test "two reconcilers serialize and issue only one effective PATCH" do
    unboxed_quantity([team_quantity: 2, runner?: false], fn state ->
      parent = self()
      first = unboxed_task(fn -> Billing.reconcile_runner_quantity(state.subscription.id) end)

      try do
        assert_receive {:quantity_retrieve, first_pid, "sub_quantity_workers"}, 5_000

        second =
          unboxed_task(fn ->
            send(parent, {:second_started, backend_pid()})
            Billing.reconcile_runner_quantity(state.subscription.id)
          end)

        try do
          assert_receive {:second_started, second_backend}, 5_000
          await_blocked(second_backend)

          send(first_pid, :release_quantity_retrieve)
          assert Task.await(first, 30_000) == {:ok, :updated}
          assert_receive {:quantity_update, ^first_pid, "sub_quantity_workers", _attrs}, 5_000

          assert_receive {:quantity_retrieve, second_pid, "sub_quantity_workers"}, 5_000
          send(second_pid, :release_quantity_retrieve)
          assert Task.await(second, 30_000) == {:ok, :converged}
          refute_receive {:quantity_update, ^second_pid, "sub_quantity_workers", _attrs}, 100
        after
          send(second.pid, :release_quantity_retrieve)
          stop_tasks([second])
        end
      after
        send(first.pid, :release_quantity_retrieve)
        stop_tasks([first])
      end
    end)
  end

  defp unboxed_quantity(opts \\ [], fun) do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      user = Fixtures.Users.create_user(%{email: "quantity-race-#{suffix}@example.test"})
      account = Fixtures.Accounts.create_account(%{name: "Quantity race #{suffix}"})

      _membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: user.id,
          role: "owner"
        )

      subject = Fixtures.Subjects.subject_for(user, account, role: :owner)

      runner =
        if Keyword.get(opts, :runner?, true),
          do: Fixtures.Runners.create_runner(account_id: account.id, connected?: false)

      paddle_id =
        if Keyword.get(opts, :runner?, true),
          do: "sub_quantity_transition",
          else: "sub_quantity_workers"

      {:ok, subscription} =
        Billing.upsert_subscription(account.id, %{
          paddle_subscription_id: paddle_id,
          paddle_price_id: "pri_team",
          plan: "team",
          status: "active",
          collection_mode: "automatic"
        })

      {:ok, agent} = Agent.start_link(fn -> remote_subscription(paddle_id, opts) end)
      Emisar.Config.put_override(:emisar, :paddle_client, PaddleClient)
      Emisar.Config.put_override(:emisar, :quantity_race_parent, self())
      Emisar.Config.put_override(:emisar, :quantity_race_agent, agent)

      try do
        fun.(%{
          account: account,
          user: user,
          subject: subject,
          runner: runner,
          subscription: subscription
        })
      after
        if Process.alive?(agent), do: Agent.stop(agent)
        Repo.delete_all(from(account in Account, where: account.id == ^account.id))
        Repo.delete_all(from(user in Emisar.Users.User, where: user.id == ^user.id))
      end
    end)
  end

  defp remote_subscription(id, opts) do
    %{
      "id" => id,
      "status" => "active",
      "collection_mode" => "automatic",
      "scheduled_change" => nil,
      "updated_at" => "2026-08-26T10:00:00.000000Z",
      "items" => [
        %{
          "quantity" => Keyword.get(opts, :team_quantity, 1),
          "product" => %{"name" => "Team", "custom_data" => %{"plan" => "team"}},
          "price" => %{
            "id" => "pri_team",
            "billing_cycle" => %{"interval" => "month", "frequency" => 1},
            "unit_price" => %{"amount" => "2000", "currency_code" => "USD"}
          }
        }
      ]
    }
  end
end
