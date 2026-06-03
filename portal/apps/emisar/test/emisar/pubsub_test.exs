defmodule Emisar.PubSubTest do
  use ExUnit.Case, async: true

  alias Emisar.PubSub

  describe "topic helpers" do
    test "account topics are scoped by account id" do
      assert PubSub.topic_for_account_runs("a1") == "account:a1:runs"
      assert PubSub.topic_for_account_approvals("a1") == "account:a1:approvals"
    end

    test "per-run and per-runner topics are scoped by id" do
      assert PubSub.topic_for_run("r1") == "run:r1"
      assert PubSub.topic_for_runner("a1") == "runner:a1"
    end

    test "topics for different accounts never collide" do
      refute PubSub.topic_for_account_runs("a1") == PubSub.topic_for_account_runs("a2")
    end
  end
end
