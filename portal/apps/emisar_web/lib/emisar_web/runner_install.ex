defmodule EmisarWeb.RunnerInstall do
  @moduledoc """
  Shared install-wizard bits — minting the single-use enrollment key and building
  the host one-liner — used by both the dedicated install page and the runners
  list's empty-state wizard (an empty account drops straight into the wizard).
  """
  alias Emisar.Runners

  # A runner usually joins within seconds of running the one-liner. If none has
  # after this grace period, reveal a troubleshooting checklist — the likely
  # funnel failure (wrong/truncated key, :443 firewalled, non-systemd host) is
  # otherwise invisible behind a "waiting" pulse that never ends.
  @troubleshoot_after_ms 35_000

  def troubleshoot_after_ms, do: @troubleshoot_after_ms

  @doc """
  Mints a fresh install key and returns `{command, key_id}` — the curl one-liner
  that enrolls a host, plus the key id (so a presence-join handler can tell THIS
  wizard's runner from any other host coming up). `{:mint_failed, nil}` on error;
  a nil key id can never match a join.
  """
  def mint_command(%Emisar.Auth.Subject{} = subject, base) do
    case Runners.mint_install_key(subject) do
      {:ok, raw, key} ->
        # Leading space keeps the key out of shell history under
        # HISTCONTROL=ignorespace / HIST_IGNORE_SPACE.
        command =
          " curl -sSL #{base}/install.sh | sudo EMISAR_ENROLLMENT_KEY=#{raw} EMISAR_URL=#{base} bash"

        {command, key.id}

      {:error, _} ->
        {:mint_failed, nil}
    end
  end
end
