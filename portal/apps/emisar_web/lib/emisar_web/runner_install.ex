defmodule EmisarWeb.RunnerInstall do
  @moduledoc """
  Shared install-wizard bits — minting the single-use enrollment key and pairing
  the domain's host one-liner with that key's id — used by both the dedicated
  install page and the runners list's empty-state wizard (an empty account drops
  straight into the wizard).
  """
  alias Emisar.Runners

  # A runner usually joins within seconds of running the one-liner. If none has
  # after this grace period, reveal a troubleshooting checklist — the likely
  # funnel failure (wrong/truncated key, :443 firewalled, non-systemd host) is
  # otherwise invisible behind a "waiting" pulse that never ends.
  @troubleshoot_after_ms 35_000

  def troubleshoot_after_ms, do: @troubleshoot_after_ms

  @doc """
  Mints a fresh install key and returns `{command, raw_key, key_id}` —
  `Runners`' curl one-liner, the key itself, and the key id (so a presence-join
  handler can tell THIS wizard's runner from any other host coming up).
  `{:mint_failed, nil, nil}` on error; a nil key id can never match a join.

  The key is returned SEPARATELY because it is no longer inside the command:
  putting it there meant a reusable credential on sudo's argv, which
  /proc/<pid>/cmdline exposes to every local user for the length of the install.
  The installer asks for it on the terminal instead, so the wizard shows it as
  its own copyable step.
  """
  def mint_command(%Emisar.Auth.Subject{} = subject, base) do
    with {:ok, raw, key} <- Runners.mint_install_key(subject),
         {:ok, command} <- Runners.enrollment_install_command(raw, base) do
      {command, raw, key.id}
    else
      {:error, _reason} -> {:mint_failed, nil, nil}
    end
  end
end
