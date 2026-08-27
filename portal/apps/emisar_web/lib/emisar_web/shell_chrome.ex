defmodule EmisarWeb.ShellChrome do
  @moduledoc """
  The console shell's own state: the nav cues and account facts that belong to
  the chrome around a page rather than to the page itself.

  Every one of these is seeded by the `on_mount` hooks in `EmisarWeb.UserAuth`
  and refreshed by the hooks attached there — no page computes any of them. They
  used to be seven separate assigns, which meant every console page spelled out
  seven literal `x={@x}` pass-throughs to `<.console_shell>`, and adding an eighth
  cue was an edit in twenty-five files.

  It is a struct rather than a map on purpose: `%ShellChrome{no_agent?: true}`
  raises on the typo instead of quietly adding a field nothing reads.
  """

  defstruct switchable_accounts: [],
            pending_approvals_count: 0,
            pending_access_requests_count: 0,
            pending_packs_count: 0,
            fleet_all_offline?: false,
            no_agents?: false,
            onboarding_incomplete?: false

  @type t :: %__MODULE__{}

  @doc """
  Merges `fields` into the socket's chrome, seeding it first when absent.

  The hooks that write here run in several places — two mount branches and four
  refresh handlers — and not always in a fixed order, so this tolerates being
  the first writer.
  """
  @spec put(Phoenix.LiveView.Socket.t(), Enumerable.t()) :: Phoenix.LiveView.Socket.t()
  def put(socket, fields) do
    current = socket.assigns[:shell_chrome] || %__MODULE__{}
    Phoenix.Component.assign(socket, :shell_chrome, struct!(current, fields))
  end
end
