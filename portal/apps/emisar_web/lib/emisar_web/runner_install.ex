defmodule EmisarWeb.RunnerInstall do
  @moduledoc """
  Shared install-wizard bits — minting the single-use enrollment key and pairing
  the domain's host one-liner with that key's id — used by both the dedicated
  install page and the runners list's empty-state wizard (an empty account drops
  straight into the wizard).
  """
  alias Emisar.{InstallCommand, Runners}

  # A runner usually joins within seconds of running the one-liner. If none has
  # after this grace period, reveal a troubleshooting checklist — the likely
  # funnel failure (wrong/truncated key, :443 firewalled, non-systemd host) is
  # otherwise invisible behind a "waiting" pulse that never ends.
  @troubleshoot_after_ms 35_000

  def troubleshoot_after_ms, do: @troubleshoot_after_ms

  @doc """
  Mints a fresh install key and returns `{command, key_id}` — `Runners`' curl
  one-liner for that key, plus the key id (so a presence-join handler can tell
  THIS wizard's runner from any other host coming up). An insecure public HTTP
  origin returns `{:insecure_transport, nil}` before a key is minted;
  `{:mint_failed, nil}` covers mint failures. A nil key id can never match a join.
  """
  def mint_command(%Emisar.Auth.Subject{} = subject, base) do
    with :ok <- InstallCommand.validate_origin(base),
         {:ok, raw, key} <- Runners.mint_install_key(subject),
         {:ok, command} <- Runners.enrollment_install_command(raw, base) do
      {command, key.id}
    else
      {:error, :insecure_base_url} -> {:insecure_transport, nil}
      {:error, :invalid_base_url} -> {:unavailable, nil}
      {:error, _reason} -> {:mint_failed, nil}
    end
  end
end
