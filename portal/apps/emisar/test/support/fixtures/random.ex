defmodule Emisar.Fixtures.Random do
  @moduledoc """
  Unique-identifier helpers for test fixtures. Use via `alias Emisar.Fixtures`
  then `Fixtures.Random.unique_email/0`. Every value is unique per VM so
  fixtures used by `async: true` tests never collide.
  """

  def unique_int, do: System.unique_integer([:positive])

  def unique_email, do: "user-#{unique_int()}@example.test"
  def unique_slug, do: "acct-#{unique_int()}"
  def unique_account_name, do: "Acct #{unique_int()}"
  def unique_runner_name, do: "runner-#{unique_int()}"
end
