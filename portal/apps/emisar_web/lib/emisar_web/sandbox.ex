defmodule EmisarWeb.Sandbox do
  @moduledoc """
  Test-only plug that lets a real browser session reach the owning test
  process's `Emisar.Config` overrides.

  `Phoenix.Ecto.SQL.Sandbox` already encodes the sandbox owner (the test pid)
  into the request `user-agent` so the request process can share the test's DB
  connection; this plug decodes that same metadata and plants the owner as
  `:last_caller_pid`, which `Emisar.Config` reads when the request process is
  not otherwise linked to the test via `$callers`.

  Wired into the endpoint only when `:sql_sandbox` is set (test env), and a
  no-op on any request whose `user-agent` carries no sandbox metadata, so dev
  and prod are never affected.
  """

  # :last_caller_pid is the sandbox-owning test process, planted so the
  # test-only `Emisar.Config` override lookup can find it across the request
  # boundary — never request/audit state (that stays an `%Emisar.RequestContext{}`).
  # credo:disable-for-this-file Emisar.Checks.NoProcessDictionary

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    with [user_agent] <- Plug.Conn.get_req_header(conn, "user-agent"),
         %{owner: owner} <- Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent) do
      Process.put(:last_caller_pid, owner)
    end

    conn
  end
end
