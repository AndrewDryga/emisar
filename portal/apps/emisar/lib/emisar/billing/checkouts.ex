defmodule Emisar.Billing.Checkouts do
  @moduledoc false
  alias Ecto.Multi
  alias Emisar.{Accounts, Billing, Crypto, Repo}
  alias Emisar.Billing.{CheckoutIntent, PaddleClient, Subscription}
  alias Emisar.Billing.{SubscriptionRetirement, SubscriptionRetirements}

  @terminal [:subscribed, :canceled, :failed]
  @commercial_fields ~w[plan billing_interval customer_id price_id quantity]a
  @page_limit 30
  @max_pages 100

  # Internal: Billing has authorized the Subject and resolved current commercial facts.
  def start(account_id, facts) do
    case current(account_id) do
      nil -> start_fresh(account_id, facts)
      intent -> resume_checkout(intent, facts)
    end
  end

  defp start_fresh(account_id, facts) do
    with :ok <- legacy_preflight(account_id, facts.customer_id),
         {:ok, reservation} <- reserve(account_id, facts) do
      case reservation do
        {:fresh, intent} ->
          with {:ok, intent} <- create_transaction(intent), do: resume_checkout(intent, facts)

        {:existing, intent} ->
          resume_checkout(intent, facts)
      end
    end
  end

  defp reserve(account_id, facts) do
    transaction(fn repo ->
      with {:ok, account} <- Accounts.fetch_and_lock_account(account_id, repo: repo),
           true <- account.paddle_customer_id == facts.customer_id,
           :ok <- ensure_available(locked_subscription(account_id, repo)),
           :ok <- ensure_no_retirements(account_id, repo) do
        case current(account_id, repo, true) do
          nil ->
            changeset =
              facts |> Map.put(:account_id, account_id) |> CheckoutIntent.Changeset.reserve()

            case repo.insert(changeset) do
              {:ok, intent} -> {:ok, {:fresh, intent}}
              error -> error
            end

          intent ->
            {:ok, {:existing, intent}}
        end
      else
        false -> {:error, :checkout_pending}
        error -> error
      end
    end)
  end

  defp create_transaction(intent) do
    attrs = %{
      customer: intent.customer_id,
      price_id: intent.price_id,
      quantity: intent.quantity,
      custom_data: %{"emisar_checkout_intent" => intent.id}
    }

    case PaddleClient.create_checkout_session(attrs) do
      {:ok, %{"id" => id}} when is_binary(id) and id != "" ->
        # Persist the identity even when the provider has not supplied a usable URL.
        if valid_provider_id?(id, "txn_") do
          transition(intent, &CheckoutIntent.Changeset.capture(&1, id))
        else
          pending(intent, :ambiguous_create)
        end

      {:error, {:http, status, _body}} when status in [400, 401, 403, 404, 422] ->
        with {:ok, _intent} <- transition(intent, &CheckoutIntent.Changeset.fail/1),
             do: {:error, :checkout_unavailable}

      _ambiguous ->
        pending(intent, :ambiguous_create)
    end
  end

  defp resume_checkout(intent, facts) do
    prepared =
      if intent.state in [:binding, :payable] and not same_facts?(intent, facts),
        do: transition(intent, &CheckoutIntent.Changeset.retire/1),
        else: {:ok, intent}

    with {:ok, intent} <- prepared,
         {:ok, recovered} <- recover(intent) do
      cond do
        recovered.state in [:canceled, :failed] ->
          start_fresh(intent.account_id, facts)

        recovered.state == :subscribed ->
          {:error, :subscription_already_active}

        same_facts?(recovered, facts) ->
          checkout_url(recovered)

        recovered.state in [:binding, :payable] ->
          with {:ok, retiring} <- transition(recovered, &CheckoutIntent.Changeset.retire/1),
               {:ok, canceled} <- recover(retiring),
               true <- canceled.state == :canceled do
            start_fresh(intent.account_id, facts)
          else
            false -> {:error, :payment_reconciling}
            error -> error
          end

        true ->
          {:error, :checkout_pending}
      end
    end
  end

  # Internal durable-row work. Never submits POST, including an empty discovery result.
  def recover(%CheckoutIntent{state: state} = intent) when state in @terminal, do: {:ok, intent}

  def recover(%CheckoutIntent{state: :creating} = intent) do
    with {:ok, transactions} <-
           list_all(
             customer: intent.customer_id,
             created_after: DateTime.to_iso8601(intent.inserted_at)
           ),
         [transaction] <- Enum.filter(transactions, &correlated?(intent, &1)),
         :ok <- verify_transaction(intent, transaction),
         {:ok, captured} <-
           transition(intent, &CheckoutIntent.Changeset.capture(&1, transaction["id"])) do
      recover(captured)
    else
      _unresolved -> pending(intent, :ambiguous_create)
    end
  end

  def recover(%CheckoutIntent{} = intent) do
    with {:ok, transaction} <- PaddleClient.retrieve_transaction(intent.transaction_id),
         :ok <- verify_transaction(intent, transaction) do
      recover_transaction(intent, transaction)
    else
      _failure -> pending(intent, :invalid_provider_data)
    end
  end

  defp recover_transaction(intent, %{"status" => "canceled"}) do
    transition(intent, &CheckoutIntent.Changeset.cancel/1)
  end

  defp recover_transaction(intent, %{"status" => status} = transaction)
       when status in ["paid", "completed"] do
    with {:ok, intent} <- transition(intent, &CheckoutIntent.Changeset.reconcile_payment/1),
         {:ok, subscription} <- paid_subscription(intent.account_id, transaction),
         result <- Billing.reconcile_discovered_subscription_data(subscription),
         :ok <- accepted_subscription(result),
         {:ok, intent} <- transition(intent, &CheckoutIntent.Changeset.subscribe/1) do
      {:ok, intent}
    else
      _unresolved -> {:error, :payment_reconciling}
    end
  end

  defp recover_transaction(intent, %{"status" => status} = transaction)
       when status in ["draft", "ready", "billed"] do
    with {:ok, disposition} <- unpaid_disposition(intent) do
      case disposition do
        {:retire, retiring} ->
          cancel_transaction(retiring)

        {:bind, current} when status in ["draft", "ready"] ->
          bind_transaction(current, transaction)

        _billed ->
          {:error, :checkout_pending}
      end
    end
  end

  defp recover_transaction(intent, _transaction), do: pending(intent, :invalid_provider_data)

  defp unpaid_disposition(intent) do
    with_intent(intent, fn repo, account, subscription, current ->
      cond do
        current.state in @terminal ->
          {:ok, {:terminal, current}}

        current.state == :payment_reconciling ->
          {:error, :payment_reconciling}

        current.state == :retiring_transaction ->
          {:ok, {:retire, current}}

        is_nil(account) or not is_nil(account.deleted_at) or live_subscription?(subscription) ->
          changeset = CheckoutIntent.Changeset.retire(current)

          case repo.update(changeset) do
            {:ok, retiring} -> {:ok, {:retire, retiring}}
            error -> error
          end

        account.paddle_customer_id != current.customer_id ->
          {:error, :checkout_pending}

        true ->
          {:ok, {:bind, current}}
      end
    end)
  end

  defp cancel_transaction(intent) do
    case PaddleClient.cancel_checkout_transaction(intent.transaction_id) do
      {:ok, %{"id" => id, "status" => "canceled"}} when id == intent.transaction_id ->
        transition(intent, &CheckoutIntent.Changeset.cancel/1)

      _unconfirmed ->
        pending(intent, :provider_unavailable)
    end
  end

  defp bind_transaction(intent, transaction) do
    if bound?(intent.account_id, intent.transaction_id, transaction) do
      make_payable(intent, transaction)
    else
      custom_data =
        Map.put(
          map_value(transaction, "custom_data"),
          "emisar_account_binding",
          Crypto.paddle_account_binding(intent.account_id, intent.transaction_id)
        )

      with {:ok, bound} <-
             PaddleClient.bind_checkout_transaction(intent.transaction_id, custom_data),
           :ok <- verify_transaction(intent, bound),
           true <- bound?(intent.account_id, intent.transaction_id, bound),
           {:ok, confirmed} <- PaddleClient.retrieve_transaction(intent.transaction_id),
           :ok <- verify_transaction(intent, confirmed),
           true <- bound?(intent.account_id, intent.transaction_id, confirmed) do
        recover_transaction(intent, confirmed)
      else
        _unconfirmed -> pending(intent, :provider_unavailable)
      end
    end
  end

  defp make_payable(intent, transaction) do
    url = map_value(transaction, "checkout")["url"]

    if valid_checkout_url?(url) do
      with_intent(intent, fn repo, account, subscription, current ->
        with :ok <- ensure_url_scope(account, subscription, current, intent),
             :ok <- ensure_no_retirements(intent.account_id, repo) do
          current |> CheckoutIntent.Changeset.payable(url) |> repo.update()
        end
      end)
    else
      pending(intent, :invalid_provider_data)
    end
  end

  defp checkout_url(intent) do
    with_intent(intent, fn repo, account, subscription, current ->
      with :ok <- ensure_url_scope(account, subscription, current, intent),
           :ok <- ensure_no_retirements(intent.account_id, repo),
           true <- current.state == :payable and valid_checkout_url?(current.checkout_url) do
        {:ok, current.checkout_url}
      else
        false -> {:error, :checkout_pending}
        error -> error
      end
    end)
  end

  defp ensure_url_scope(account, subscription, current, expected) do
    cond do
      is_nil(account) or not is_nil(account.deleted_at) ->
        {:error, :account_closed}

      account.paddle_customer_id != expected.customer_id ->
        {:error, :checkout_pending}

      not is_nil(account.disabled_at) ->
        {:error, :checkout_pending}

      current.id != expected.id or current.state not in [:binding, :payable] ->
        {:error, :checkout_pending}

      true ->
        ensure_available(subscription)
    end
  end

  defp valid_checkout_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} ->
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
          is_nil(uri.userinfo) and uri.port in 1..65_535 and
          not Regex.match?(~r/[\x00-\x20\x7f]/, url)

      {:error, _part} ->
        false
    end
  end

  defp valid_checkout_url?(_url), do: false

  defp same_facts?(intent, facts),
    do: Map.take(intent, @commercial_fields) == Map.take(facts, @commercial_fields)

  # Pure provider boundary reused by signed subscription recovery. Original transaction
  # facts do not constrain later legitimate quantity/cadence changes on its subscription.
  def verify_transaction(intent, transaction) when is_map(transaction) do
    id = transaction["id"]

    valid_id? =
      valid_provider_id?(id, "txn_") and
        (is_nil(intent.transaction_id) or id == intent.transaction_id)

    item =
      case transaction["items"] do
        [item] when is_map(item) -> item
        _ -> %{}
      end

    price_id = map_value(item, "price")["id"] || item["price_id"]

    if valid_id? and correlated?(intent, transaction) and price_id == intent.price_id and
         item["quantity"] == intent.quantity and transaction["collection_mode"] == "automatic" and
         transaction["origin"] == "api" and transaction["customer_id"] == intent.customer_id,
       do: :ok,
       else: {:error, :invalid_checkout_transaction}
  end

  def verify_transaction(_intent, _transaction), do: {:error, :invalid_checkout_transaction}

  defp correlated?(intent, transaction),
    do: map_value(transaction, "custom_data")["emisar_checkout_intent"] == intent.id

  defp bound?(account_id, transaction_id, data) do
    case Crypto.verify_paddle_account_binding(
           map_value(data, "custom_data")["emisar_account_binding"]
         ) do
      {:ok, {^account_id, ^transaction_id}} -> true
      _invalid -> false
    end
  end

  defp paid_subscription(account_id, transaction) do
    id = transaction["subscription_id"]

    with true <- valid_provider_id?(id, "sub_"),
         true <- bound?(account_id, transaction["id"], transaction),
         {:ok, subscription} <- PaddleClient.retrieve_subscription(id),
         {:ok, proof} <- SubscriptionRetirements.verify_candidate(subscription, []),
         true <- proof.account_id == account_id and proof.transaction_id == transaction["id"] do
      {:ok, proof.subscription}
    else
      _unresolved -> {:error, :payment_reconciling}
    end
  end

  defp accepted_subscription({:ok, %Subscription{}}), do: :ok
  defp accepted_subscription({:ok, %SubscriptionRetirement{}}), do: :ok
  defp accepted_subscription(:ok), do: :ok
  defp accepted_subscription(_result), do: {:error, :payment_reconciling}

  defp legacy_preflight(account_id, customer_id) do
    case list_all(customer: customer_id) do
      {:ok, transactions} ->
        Enum.reduce_while(transactions, :ok, fn transaction, :ok ->
          case legacy_transaction(account_id, customer_id, transaction) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      _incomplete ->
        {:error, :legacy_checkout_pending}
    end
  end

  defp legacy_transaction(account_id, customer_id, transaction) do
    if bound?(account_id, transaction["id"], transaction) do
      with {:ok, fresh} when is_map(fresh) <- PaddleClient.retrieve_transaction(transaction["id"]),
           true <- fresh["id"] == transaction["id"] and fresh["customer_id"] == customer_id,
           true <- bound?(account_id, fresh["id"], fresh) do
        legacy_status(account_id, fresh)
      else
        _unresolved -> {:error, :legacy_checkout_pending}
      end
    else
      :ok
    end
  end

  defp legacy_status(_account_id, %{"status" => "canceled"}), do: :ok

  defp legacy_status(account_id, %{"status" => status} = transaction)
       when status in ["paid", "completed"] do
    with {:ok, subscription} <- paid_subscription(account_id, transaction) do
      if subscription["status"] == "canceled" do
        :ok
      else
        case Billing.reconcile_discovered_subscription_data(subscription) do
          {:ok, %SubscriptionRetirement{}} -> {:error, :subscription_retirement_pending}
          {:ok, %Subscription{}} -> {:error, :subscription_already_active}
          :ok -> {:error, :subscription_already_active}
          _unresolved -> {:error, :payment_reconciling}
        end
      end
    end
  end

  defp legacy_status(_account_id, _transaction), do: {:error, :legacy_checkout_pending}

  defp list_all(attrs), do: list_page(attrs, nil, MapSet.new(), [], 0)

  defp list_page(_attrs, _cursor, _seen, _transactions, @max_pages),
    do: {:error, :checkout_scan_limit}

  defp list_page(attrs, cursor, seen, transactions, page) do
    with {:ok, %{transactions: rows, next_after: next}} <-
           PaddleClient.list_checkout_transactions(
             Keyword.merge(attrs, limit: @page_limit, after: cursor)
           ),
         true <- is_list(rows) and length(rows) <= @page_limit,
         true <- Enum.all?(rows, &valid_list_transaction?(&1, attrs[:customer])) do
      cond do
        is_nil(next) ->
          {:ok, transactions ++ rows}

        valid_provider_id?(next, "txn_") and not MapSet.member?(seen, next) and next != cursor ->
          list_page(attrs, next, MapSet.put(seen, next), transactions ++ rows, page + 1)

        true ->
          {:error, :malformed_checkout_page}
      end
    else
      _incomplete -> {:error, :malformed_checkout_page}
    end
  end

  defp valid_list_transaction?(data, customer_id) when is_map(data) do
    valid_provider_id?(data["id"], "txn_") and data["customer_id"] == customer_id and
      data["origin"] == "api" and data["collection_mode"] == "automatic" and
      is_binary(data["status"])
  end

  defp valid_list_transaction?(_data, _customer_id), do: false

  defp valid_provider_id?(id, prefix) when is_binary(id) do
    String.starts_with?(id, prefix) and byte_size(id) > byte_size(prefix) and byte_size(id) <= 128 and
      Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)
  end

  defp valid_provider_id?(_id, _prefix), do: false

  defp current(account_id, repo \\ Repo, lock? \\ false) do
    query = CheckoutIntent.Query.by_account_id(account_id) |> CheckoutIntent.Query.pending()
    query = if lock?, do: CheckoutIntent.Query.lock_for_update(query), else: query
    repo.peek(query)
  end

  defp locked_subscription(account_id, repo) do
    Subscription.Query.all()
    |> Subscription.Query.by_account_id(account_id)
    |> Subscription.Query.lock_for_update()
    |> repo.peek()
  end

  defp map_value(data, key) when is_map(data) do
    case data[key] do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp map_value(_data, _key), do: %{}

  defp live_subscription?(%Subscription{paddle_subscription_id: id, status: status}),
    do: is_binary(id) and status != "canceled"

  defp live_subscription?(_subscription), do: false

  defp ensure_available(subscription) do
    if(live_subscription?(subscription), do: {:error, :subscription_already_active}, else: :ok)
  end

  defp ensure_no_retirements(account_id, repo) do
    pending =
      account_id
      |> SubscriptionRetirement.Query.by_account_id()
      |> SubscriptionRetirement.Query.pending()
      |> repo.exists?()

    if pending, do: {:error, :subscription_retirement_pending}, else: :ok
  end

  defp transition(intent, changeset_fun) do
    with_intent(intent, fn repo, _account, _subscription, current ->
      if current.state in @terminal,
        do: {:ok, current},
        else: current |> changeset_fun.() |> repo.update()
    end)
  end

  defp pending(intent, category) do
    case transition(intent, &CheckoutIntent.Changeset.record_failure(&1, category)) do
      {:ok, _intent} -> {:error, :checkout_pending}
      _failure -> {:error, :checkout_pending}
    end
  end

  defp with_intent(intent, fun) do
    transaction(fn repo ->
      account =
        case Accounts.fetch_and_lock_account(intent.account_id,
               repo: repo,
               include_deleted?: true
             ) do
          {:ok, account} -> account
          {:error, :not_found} -> nil
        end

      subscription = locked_subscription(intent.account_id, repo)

      current =
        intent.id
        |> CheckoutIntent.Query.by_id()
        |> CheckoutIntent.Query.by_account_id(intent.account_id)
        |> CheckoutIntent.Query.lock_for_update()
        |> repo.peek()

      if current,
        do: fun.(repo, account, subscription, current),
        else: {:error, :checkout_pending}
    end)
  end

  defp transaction(fun) do
    Multi.new()
    |> Multi.run(:checkout, fn repo, _changes -> fun.(repo) end)
    |> Repo.commit_multi()
    |> case do
      {:ok, %{checkout: result}} -> {:ok, result}
      error -> error
    end
  end

  # Internal: prepare cleanup before Accounts' final DB-only closure transaction.
  def cancel_for_close(account_id) do
    case current(account_id) do
      nil ->
        :ok

      %CheckoutIntent{state: :creating} ->
        {:error, :checkout_pending}

      %CheckoutIntent{state: :payment_reconciling} = intent ->
        case recover(intent) do
          {:ok, %CheckoutIntent{state: :subscribed}} -> :ok
          _unresolved -> {:error, :payment_reconciling}
        end

      intent ->
        with {:ok, retiring} <- transition(intent, &CheckoutIntent.Changeset.retire/1),
             {:ok, %CheckoutIntent{state: state}} when state in [:canceled, :subscribed] <-
               recover(retiring) do
          :ok
        else
          _unresolved -> {:error, :payment_reconciling}
        end
    end
  end
end
