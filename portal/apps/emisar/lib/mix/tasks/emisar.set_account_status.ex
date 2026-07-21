defmodule Mix.Tasks.Emisar.SetAccountStatus do
  @shortdoc "Enable or disable an account"
  @moduledoc """
  Reversibly enable or disable an account from a release shell. The reason is
  stored on the account lifecycle audit event.

      mix emisar.set_account_status acme disabled "Abuse investigation"
      mix emisar.set_account_status 019f3582-... enabled "Investigation resolved"
  """
  use Mix.Task
  alias Emisar.Auth.Subject

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [id_or_slug, status, reason] -> set_status(id_or_slug, status, reason)
      _ -> Mix.raise("Usage: mix emisar.set_account_status <account> <enabled|disabled> <reason>")
    end
  end

  defp set_status(id_or_slug, status, reason) when status in ["enabled", "disabled"] do
    with {:ok, account} <-
           Emisar.Accounts.fetch_account_by_id_or_slug_including_disabled(id_or_slug),
         subject = %Subject{account: account},
         {:ok, account} <-
           Emisar.Accounts.set_account_disabled_for_support(
             account.id,
             status == "disabled",
             reason,
             subject
           ) do
      state = if is_nil(account.disabled_at), do: "enabled", else: "disabled"
      Mix.shell().info("#{account.name} (#{account.slug}) is #{state}.")
    else
      {:error, :not_found} -> Mix.raise("No account matches #{inspect(id_or_slug)}")
      {:error, :invalid_reason} -> Mix.raise("Reason must contain 1 to 500 bytes")
      {:error, reason} -> Mix.raise("Could not update account: #{inspect(reason)}")
    end
  end

  defp set_status(_id_or_slug, status, _reason),
    do: Mix.raise("Unknown status #{inspect(status)}; expected enabled or disabled")
end
