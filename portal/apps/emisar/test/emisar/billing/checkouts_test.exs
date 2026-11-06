defmodule Emisar.Billing.CheckoutsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Billing, Config, Crypto, Fixtures, Repo}
  alias Emisar.Billing.CheckoutIntent

  setup do
    store = Fixtures.Billing.start_provider()
    {_owner, account, subject} = Fixtures.Subjects.owner_subject()
    {:ok, _customer, account} = Billing.ensure_paddle_customer(account, subject)
    %{account: account, subject: subject, store: store}
  end

  test "same facts reuse one payable transaction", %{account: account, subject: subject} do
    assert {:ok, url} = Billing.start_checkout(account, "team", :month, subject)

    assert Billing.verify_checkout_return(checkout_return(url)) ==
             {:ok, %{account_id: account.id, transaction_id: intent(account).transaction_id}}

    assert {:ok, resumed} = Billing.start_checkout(account, "team", :month, subject)
    assert without_checkout_return(resumed) == without_checkout_return(url)
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
    assert intent(account).state == :payable
  end

  test "fresh and resumed URLs preserve provider parameters and replace only the return state", %{
    account: account,
    subject: subject
  } do
    provider_url =
      "https://checkout.example.test/?_ptxn=txn_review&extra=a%20b&extra=c&emisar_return=forged&emisar%5Freturn=also-forged#payment"

    Config.put_override(:emisar, :billing_test_after_call, fn
      :create, _args, {:ok, transaction} ->
        updated =
          Fixtures.Billing.set_transaction(transaction["id"], %{
            "checkout" => %{"url" => provider_url}
          })

        {:ok, updated}

      _operation, _args, result ->
        result
    end)

    expected = "https://checkout.example.test/?_ptxn=txn_review&extra=a%20b&extra=c#payment"

    for _attempt <- 1..2 do
      assert {:ok, url} = Billing.start_checkout(account, "team", :month, subject)
      assert without_checkout_return(url) == expected

      assert Billing.verify_checkout_return(checkout_return(url)) ==
               {:ok, %{account_id: account.id, transaction_id: intent(account).transaction_id}}
    end

    assert intent(account).checkout_url == provider_url
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "a cadence change cancels the billed old transaction before creating another", %{
    account: account,
    subject: subject,
    store: store
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    old = intent(account)
    Fixtures.Billing.set_transaction(old.transaction_id, %{"status" => "billed"})

    Config.put_override(:emisar, :billing_test_before_call, fn
      :create, %{price_id: "pri_stub_team_year"} ->
        assert Agent.get(store, & &1.transactions[old.transaction_id]["status"]) == "canceled"

      _operation, _args ->
        :ok
    end)

    assert {:ok, _url} = Billing.start_checkout(account, "team", :year, subject)
    assert Repo.reload!(old).state == :canceled
    assert intent(account).billing_interval == :year
    assert intent(account).transaction_id != old.transaction_id
  end

  test "a lost create response discovers the accepted transaction without another POST", %{
    account: account,
    subject: subject
  } do
    Config.put_override(:emisar, :billing_test_after_call, fn
      :create, _args, _result -> {:error, :timeout}
      _operation, _args, result -> result
    end)

    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :month, subject)
    assert intent(account).state == :creating
    assert is_nil(intent(account).transaction_id)
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "a committed reservation with no discovered transaction never submits POST", %{
    account: account,
    subject: subject
  } do
    reserved = Fixtures.Billing.create_checkout_intent(account)
    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :month, subject)
    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :year, subject)
    assert Repo.reload!(reserved).state == :creating
    refute_received {:paddle, :create, _attrs, _caller}
  end

  # Paddle creates transactions synchronously, so a reservation whose clean
  # discovery is still empty an hour later is one whose create never landed.
  # Failing it is what lets the workspace ever check out (or close) again.
  test "an hour-old reservation with a clean empty discovery fails, and the next click reserves fresh",
       %{account: account, subject: subject} do
    abandoned = abandoned_reservation(account)
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert Repo.reload!(abandoned).state == :failed
    assert intent(account).state == :payable
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "an abandoned reservation no longer blocks closing the account", %{account: account} do
    abandoned = abandoned_reservation(account)
    assert Emisar.Billing.Checkouts.cancel_for_close(account.id) == :ok
    assert Repo.reload!(abandoned).state == :failed
    refute_received {:paddle, :create, _attrs, _caller}

    # A young reservation still holds closure: its create may yet land.
    young = Fixtures.Billing.create_checkout_intent(account)
    assert Emisar.Billing.Checkouts.cancel_for_close(account.id) == {:error, :checkout_pending}
    assert Repo.reload!(young).state == :creating
  end

  test "captures the provider ID before a missing URL and recovers it", %{
    account: account,
    subject: subject
  } do
    Config.put_override(:emisar, :billing_test_after_call, fn
      :create, _args, {:ok, transaction} ->
        updated = Fixtures.Billing.set_transaction(transaction["id"], %{"checkout" => nil})
        {:ok, updated}

      _operation, _args, result ->
        result
    end)

    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :month, subject)
    pending = intent(account)
    assert pending.state == :binding
    assert is_binary(pending.transaction_id)

    Fixtures.Billing.set_transaction(pending.transaction_id, %{
      "checkout" => %{"url" => "https://checkout.example.test/recovered"}
    })

    assert {:ok, url} = Billing.start_checkout(account, "team", :month, subject)
    assert without_checkout_return(url) == "https://checkout.example.test/recovered"

    assert Billing.verify_checkout_return(checkout_return(url)) ==
             {:ok, %{account_id: account.id, transaction_id: pending.transaction_id}}

    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "a lost binding response recovers by GET without re-creating", %{
    account: account,
    subject: subject
  } do
    Config.put_override(:emisar, :billing_test_after_call, fn
      :bind, _args, _result -> {:error, :timeout}
      _operation, _args, result -> result
    end)

    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :month, subject)
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert_received {:paddle, :bind, _args, _caller}
    refute_received {:paddle, :bind, _args, _caller}
    assert_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "unconfirmed cancellation blocks replacement and GET repairs accepted cancellation", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    old = intent(account)
    assert_received {:paddle, :create, _attrs, _caller}

    Config.put_override(:emisar, :billing_test_after_call, fn
      :cancel_transaction, _args, _result -> {:error, :timeout}
      _operation, _args, result -> result
    end)

    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :year, subject)
    refute_received {:paddle, :create, _attrs, _caller}
    assert Repo.reload!(old).state == :retiring_transaction
    assert {:ok, _url} = Billing.start_checkout(account, "team", :year, subject)
    assert Repo.reload!(old).state == :canceled
  end

  test "payment without a subscription link is a barrier", %{account: account, subject: subject} do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    old = intent(account)
    Fixtures.Billing.set_transaction(old.transaction_id, %{"status" => "paid"})
    assert_received {:paddle, :create, _attrs, _caller}

    assert {:error, :payment_reconciling} =
             Billing.start_checkout(account, "team", :year, subject)

    assert {:error, :payment_reconciling} =
             Billing.start_checkout(account, "team", :month, subject)

    assert Repo.reload!(old).state == :payment_reconciling
    refute_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :cancel_transaction, _id, _caller}
  end

  test "another account's transaction on a shared customer never blocks discovery", %{
    account: account,
    subject: subject
  } do
    abandoned = abandoned_reservation(account)
    other = Fixtures.Accounts.create_account(%{paddle_customer_id: account.paddle_customer_id})
    Fixtures.Billing.create_legacy_transaction(other)

    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    assert Repo.reload!(abandoned).state == :failed
    refute_received {:paddle, :cancel_transaction, _transaction_id, _caller}
  end

  # Only a complete, clean discovery may fail an abandoned reservation: an
  # incomplete one could hide the accepted transaction a second POST would duplicate.
  test "malformed or cyclic discovery scans keep an abandoned reservation without POST", %{
    account: account,
    subject: subject
  } do
    abandoned = abandoned_reservation(account)

    for reply <- [
          {:error, :timeout},
          {:ok, %{transactions: [nil], next_after: nil}},
          {:ok, %{transactions: [], next_after: "txn_repeat"}}
        ] do
      Config.put_override(:emisar, :billing_test_after_call, fn
        :list_transactions, _args, _result -> reply
        _operation, _args, result -> result
      end)

      assert {:error, :checkout_pending} =
               Billing.start_checkout(account, "team", :month, subject)

      assert Repo.reload!(abandoned).state == :creating
    end

    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "malformed nested provider fields and non-web URLs never become payable", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    current = intent(account)
    {:ok, original} = Billing.PaddleClient.retrieve_transaction(current.transaction_id)

    invalid =
      [
        %{"custom_data" => "not a map"},
        %{"items" => [%{"price" => "not a map", "quantity" => 1}]},
        %{"checkout" => "not a map"}
      ] ++
        Enum.map(
          [
            "javascript:alert(1)",
            "https://user:pass@example.test/",
            "https://example.test:bad/x",
            "http://[bad",
            "https://example.test:65536/x"
          ],
          &%{"checkout" => %{"url" => &1}}
        )

    for attrs <- invalid do
      Fixtures.Billing.set_transaction(current.transaction_id, Map.merge(original, attrs))

      assert {:error, :checkout_pending} =
               Billing.start_checkout(account, "team", :month, subject)
    end
  end

  test "binding is the existing account and transaction HMAC, not the intent UUID", %{
    account: account,
    subject: subject
  } do
    assert {:ok, _url} = Billing.start_checkout(account, "team", :month, subject)
    current = intent(account)
    assert_received {:paddle, :bind, {id, metadata}, _caller}
    assert id == current.transaction_id
    assert metadata["emisar_checkout_intent"] == current.id

    assert Crypto.verify_paddle_account_binding(metadata["emisar_account_binding"]) ==
             {:ok, {account.id, id}}
  end

  test "discovery pagination caps keep an abandoned reservation without POST", %{
    account: account,
    subject: subject
  } do
    abandoned = abandoned_reservation(account)

    Config.put_override(:emisar, :billing_test_after_call, fn
      :list_transactions, _args, _result ->
        page = Process.get(:discovery_pages, 0) + 1
        Process.put(:discovery_pages, page)
        {:ok, %{transactions: [], next_after: "txn_page_#{page}"}}

      _, _, result ->
        result
    end)

    assert {:error, :checkout_pending} =
             Billing.start_checkout(account, "team", :month, subject)

    assert Process.get(:discovery_pages) == 100
    assert Repo.reload!(abandoned).state == :creating
    refute_received {:paddle, :create, _attrs, _caller}
  end

  test "ambiguous discovery never chooses one of several correlated transactions", %{
    account: account,
    subject: subject
  } do
    reserved = Fixtures.Billing.create_checkout_intent(account)

    for _ <- 1..2 do
      assert {:ok, _transaction} =
               Billing.PaddleClient.create_checkout_session(%{
                 customer: account.paddle_customer_id,
                 price_id: reserved.price_id,
                 quantity: reserved.quantity,
                 custom_data: %{"emisar_checkout_intent" => reserved.id}
               })

      assert_received {:paddle, :create, _attrs, _caller}
    end

    assert {:error, :checkout_pending} = Billing.start_checkout(account, "team", :month, subject)
    assert Repo.reload!(reserved).state == :creating
    refute_received {:paddle, :create, _attrs, _caller}
    refute_received {:paddle, :bind, _args, _caller}
  end

  defp intent(account) do
    account.id
    |> CheckoutIntent.Query.by_account_id()
    |> CheckoutIntent.Query.pending()
    |> Repo.peek()
  end

  # A `creating` reservation past the hour-long grace for a lost create response.
  defp abandoned_reservation(account) do
    account
    |> Fixtures.Billing.create_checkout_intent()
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -3_601, :second))
    |> Repo.update!()
  end

  defp checkout_return(url), do: URI.decode_query(URI.parse(url).query)["emisar_return"]

  # The signed return is minted per hand-out; the rest is the provider's URL.
  defp without_checkout_return(url) do
    uri = URI.parse(url)

    query =
      uri.query
      |> String.split("&", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "emisar_return="))
      |> Enum.join("&")

    URI.to_string(%{uri | query: if(query == "", do: nil, else: query)})
  end
end
