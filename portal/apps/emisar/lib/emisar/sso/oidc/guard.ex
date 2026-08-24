defmodule Emisar.SSO.OIDC.Guard do
  @moduledoc """
  A loopback HTTP proxy that every OIDC fetch is routed through, so the SSRF
  policy is applied at CONNECT time instead of to a URL we hope is the one dialled.

  ## Why a proxy

  Inspecting the discovery document is not enough, and neither is fetching it
  ourselves. `oidcc` passes a custom httpc profile through every request, and a
  pinned adapter patch disables automatic redirects and Retry-After retries.
  The proxy remains the network boundary for every first-party endpoint: a URL
  that escaped validation, including an HTTPS→HTTP downgrade, still cannot dial
  around the address policy.

  `proxy` is a per-PROFILE option (`httpc:set_options/2`). A dedicated profile
  pointed here therefore covers discovery, JWKS, token exchange, and PAR without
  replacing oidcc's HTTP stack.

  ## What it enforces

  * **CONNECT only.** A plain absolute-URI request means `http://`, which is how
    an HTTPS→HTTP downgrade would arrive. Refused.
  * **The address, not the name.** The host is resolved here and the resolved
    address is checked against `Emisar.SSO.IssuerUrl.address_allowed?/1`.
  * **Dialled by address.** We connect to the exact address we checked, so a name
    that resolves publicly for one lookup and privately for the next cannot be
    rebound between the check and the connection.
  * **TLS is untouched.** The tunnel is opaque; `httpc` completes its own
    handshake with the origin and verifies the certificate against the hostname it
    asked for. The guard never sees plaintext and cannot be a MITM.
  """
  use GenServer
  alias Emisar.SSO.IssuerUrl
  alias Emisar.SSO.OIDC.Guard.Relay
  require Logger

  @profile :emisar_oidc
  @tasks Emisar.SSO.OIDC.GuardTasks
  # A relay that never times out, and an unbounded number of them, is a way to
  # exhaust the guard without the process ever looking unhealthy — SSO then fails
  # for everyone while the supervisor sees nothing wrong. A tunnel gets an idle
  # deadline, an absolute lifetime, one combined TLS-byte budget, and a pool cap.
  @tunnel_max_lifetime 30_000
  # Discovery, JWKS and token documents are normally tens of KiB. One MiB covers
  # a deliberately large key set while bounding the bytes httpc can buffer from
  # any one opaque keep-alive tunnel (both directions combined).
  @tunnel_max_bytes 1_024 * 1_024
  @max_tunnels 64
  @connect_timeout 10_000
  @max_request_headers 64
  # One CONNECT's whole envelope: a line cap OTP enforces in the packet decoder,
  # and one deadline covering the request rather than each line separately.
  @max_header_bytes 4_096
  @request_timeout 10_000

  @doc "The httpc profile every OIDC request must use."
  def profile, do: @profile

  @doc "The loopback port the guard is listening on. For tests that speak to it."
  def port, do: GenServer.call(__MODULE__, :port)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Loopback only: this is an internal seam, never a proxy anything else may use.
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        packet: :raw
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    with :ok <- start_profile(port) do
      # Accepting happens in its OWN process. Looping inside the GenServer with
      # `{:continue, :accept}` never yields to the mailbox — the continue runs
      # immediately and forever, so every call to this process timed out.
      {:ok, acceptor} = Task.Supervisor.start_child(@tasks, fn -> accept_loop(listener) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)
      {:ok, %{listener: listener, port: port, acceptor: acceptor}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        # One process per tunnel: a client that disappears mid-relay must not take
        # the acceptor with it. Past the cap the connection is closed rather than
        # queued, so a flood cannot grow the pool without bound.
        if open_tunnels() >= @max_tunnels do
          Logger.warning("OIDC guard refused a tunnel: #{@max_tunnels} already open")
          :gen_tcp.close(socket)
        else
          # The child WAITS to be handed the socket. Starting it on `serve/1`
          # directly raced `controlling_process/2`: the task could reach `recv`
          # while the acceptor still owned the socket, get `{:error, :not_owner}`,
          # and close without answering — an empty reply where a 403 belonged.
          # It only showed under load, which is what made it look like a flake.
          deadline = deadline_after(@tunnel_max_lifetime)

          {:ok, pid} =
            Task.Supervisor.start_child(@tasks, fn -> await_socket(socket, deadline) end)

          :ok = :gen_tcp.controlling_process(socket, pid)
          send(pid, {:owned, socket})
        end

        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listener)
    end
  end

  # httpc is configured once, against the port we just bound. NoProxy is empty on
  # purpose — an exception list is a bypass list.
  defp start_profile(port) do
    _ = :inets.start(:httpc, profile: @profile)

    :httpc.set_options(
      [
        {:proxy, {{~c"127.0.0.1", port}, []}},
        {:https_proxy, {{~c"127.0.0.1", port}, []}},
        # Zero persistent sessions makes httpc add `Connection: close` to every
        # request. One oidcc operation therefore owns at most one Guard slot at a
        # time: discovery/JWKS/PAR/token requests release their tunnel before the
        # next begins instead of accumulating for OTP's default two-minute
        # keep-alive window.
        {:max_sessions, 0}
      ],
      @profile
    )
  end

  defp await_socket(socket, deadline) do
    receive do
      {:owned, ^socket} -> serve_until_deadline(socket, deadline)
    after
      min(@connect_timeout, remaining(deadline)) -> :gen_tcp.close(socket)
    end
  end

  # The explicit timeouts below make each operation return a useful reason. This
  # timer is the hard backstop: an unexpected blocking call or a mailbox kept busy
  # by continuous TCP data still cannot outlive the accept-time deadline. Owned
  # sockets close automatically when the task exits.
  defp serve_until_deadline(socket, deadline) do
    case :timer.exit_after(remaining(deadline), self(), :shutdown) do
      {:ok, timer} ->
        try do
          serve(socket, deadline)
        after
          _ = :timer.cancel(timer)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp serve(socket, deadline) do
    case read_request_line(socket, deadline) do
      {:ok, "CONNECT " <> rest} ->
        rest |> String.split(" ", parts: 2) |> hd() |> tunnel(socket, deadline)

      {:ok, line} ->
        # Anything that is not CONNECT reached us as cleartext, which for an OIDC
        # fetch means a redirect downgraded the scheme.
        Logger.warning("OIDC guard refused a cleartext request: #{inspect(first_token(line))}")
        refuse(socket, "403 Forbidden", deadline)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp tunnel(authority, socket, deadline) do
    with :ok <- ensure_time_remaining(deadline),
         {:ok, host, port} <- split_authority(authority),
         {:ok, address} <- resolve_allowed(host, port, deadline) do
      connect(socket, host, address, port, deadline)
    else
      {:error, {:blocked, host, address}} ->
        Logger.warning("OIDC guard blocked #{host} → #{:inet.ntoa(address)}")
        refuse(socket, "403 Forbidden", deadline)

      {:error, reason} ->
        Logger.warning("OIDC guard refused #{inspect(authority)}: #{inspect(reason)}")
        refuse(socket, "502 Bad Gateway", deadline)
    end
  end

  # Resolve ONCE and hand back the address, so the connection below dials the thing
  # that was judged rather than repeating the lookup. An IP literal needs no
  # lookup at all; a name gets exactly one.
  defp resolve_allowed(host, port, deadline) do
    charlist = String.to_charlist(host)

    if declared?(host, port) do
      resolve_declared(host, charlist, deadline)
    else
      case :inet.parse_address(charlist) do
        {:ok, address} -> judge(host, address)
        {:error, _reason} -> resolve_and_judge(host, charlist, deadline)
      end
    end
  end

  @doc """
  Has this deployment declared this exact `host:port` as one of its own identity
  providers?

  Development and test builds run their IdP on a private address, since a local
  Keycloak cannot be given a public one. Such an endpoint is named EXACTLY by the
  harness, and the list is empty in production builds.

  **Host AND port.** The hostname reaching this function comes from a discovery
  document, which is attacker-influenced, so a host-only declaration let any
  tenant's document name a declared host and reach it on ANY TLS-speaking port —
  the declaration was meant to admit one endpoint, not a machine. The port closes
  that.

  What it does NOT do is bind the exemption to the provider that asked. In a
  development or test build which declares an endpoint, any tenant's document may
  still name that endpoint; production builds refuse to load the list.

  Public because the guard answers CONNECTs in a process with no relationship to
  any test, so this is the seam a test can actually reach.
  """
  def declared?(host, port) do
    wanted = "#{String.downcase(host)}:#{port}"

    :emisar
    |> Emisar.Config.get_env(:sso_allowed_idp_hosts, [])
    |> Enum.any?(fn declared ->
      normalized = declared |> String.trim() |> String.downcase()
      normalized == wanted
    end)
  end

  # Still resolved, and still dialled by the address we resolved — being declared
  # exempts the host from the ADDRESS policy, not from being pinned.
  defp resolve_declared(host, charlist, deadline) do
    case :inet.parse_address(charlist) do
      {:ok, address} -> declared_address(host, address)
      {:error, _reason} -> resolve_declared_name(host, charlist, deadline)
    end
  end

  defp resolve_declared_name(host, charlist, deadline) do
    case resolve(charlist, deadline) do
      {:ok, address} -> declared_address(host, address)
      {:error, reason} -> {:error, reason}
    end
  end

  defp declared_address(host, address) do
    Logger.info("OIDC guard allowed declared IdP #{host} → #{:inet.ntoa(address)}")
    {:ok, address}
  end

  defp resolve_and_judge(host, charlist, deadline) do
    case resolve(charlist, deadline) do
      {:ok, address} -> judge(host, address)
      {:error, reason} -> {:error, reason}
    end
  end

  defp judge(host, address) do
    if IssuerUrl.address_allowed?(address),
      do: {:ok, address},
      else: {:error, {:blocked, host, address}}
  end

  defp resolve(charlist, deadline) do
    case :inet.getaddr(charlist, :inet, remaining(deadline)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :inet.getaddr(charlist, :inet6, remaining(deadline))
    end
  end

  defp connect(client, host, address, port, deadline) do
    socket_opts = [
      :binary,
      active: false,
      packet: :raw,
      send_timeout: remaining(deadline),
      send_timeout_close: true
    ]

    case :gen_tcp.connect(address, port, socket_opts, min(@connect_timeout, remaining(deadline))) do
      {:ok, origin} ->
        case send_with_deadline(client, "HTTP/1.1 200 Connection Established\r\n\r\n", deadline) do
          :ok -> Relay.run(client, origin, deadline, @tunnel_max_bytes)
          {:error, _reason} -> close_both(client, origin)
        end

      {:error, reason} ->
        Logger.warning("OIDC guard could not reach #{host}: #{inspect(reason)}")
        refuse(client, "502 Bad Gateway", deadline)
    end
  end

  defp close_both(client, origin) do
    :gen_tcp.close(client)
    :gen_tcp.close(origin)
  end

  defp read_request_line(socket, tunnel_deadline) do
    # A cap per line AND one deadline for the whole request. Counting lines alone
    # bounded nothing that matters: an unset packet_size lets a single line grow
    # without limit, and a fresh timeout per line let one client hold a task for
    # minutes by trickling headers.
    :ok = :inet.setopts(socket, packet: :line, packet_size: @max_header_bytes)
    deadline = min(tunnel_deadline, deadline_after(@request_timeout))

    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, line} ->
        with :ok <- drain_headers(socket, @max_request_headers, deadline) do
          :ok = :inet.setopts(socket, packet: :raw)
          {:ok, String.trim(line)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deadline_after(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp deadline_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp ensure_time_remaining(deadline) do
    if deadline_expired?(deadline), do: {:error, :timeout}, else: :ok
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp send_with_deadline(socket, data, deadline) do
    with :ok <- ensure_time_remaining(deadline),
         :ok <-
           :inet.setopts(socket,
             send_timeout: remaining(deadline),
             send_timeout_close: true
           ) do
      :gen_tcp.send(socket, data)
    end
  end

  # A CONNECT is a whole request: the line, then its headers, then a blank line.
  # Reading only the line left `Host: …\r\n\r\n` sitting in the socket, and the
  # relay then forwarded it to the IdP as the opening bytes of the TLS
  # ClientHello — which the IdP answers by hanging up. Every unit test here sends
  # a header-less CONNECT and asserts a refusal, so the bytes never reached a
  # relay and nothing caught it; `./run e2e sso` did, as a TLS-trust failure that
  # was really a framing one.
  defp drain_headers(_socket, 0, _deadline), do: {:error, :too_many_headers}

  defp drain_headers(socket, headers_left, deadline) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, line} ->
        if String.trim(line) == "" do
          :ok
        else
          drain_headers(socket, headers_left - 1, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp split_authority(authority) do
    case String.split(authority, ":") do
      # Bracketed IPv6 keeps its colons; take the port off the end and unwrap.
      parts when length(parts) > 2 ->
        {port, host} =
          parts |> Enum.reverse() |> then(fn [p | rest] -> {p, Enum.reverse(rest)} end)

        parse_port(
          host |> Enum.join(":") |> String.trim_leading("[") |> String.trim_trailing("]"),
          port
        )

      [host, port] ->
        parse_port(host, port)

      _ ->
        {:error, :malformed_authority}
    end
  end

  defp parse_port(host, port) when host != "" do
    case Integer.parse(port) do
      {number, ""} when number > 0 and number < 65_536 -> {:ok, host, number}
      _ -> {:error, :malformed_authority}
    end
  end

  defp parse_port(_host, _port), do: {:error, :malformed_authority}

  # Shut the write side down before closing. A bare close can discard whatever is
  # still in the send buffer, so the refusal arrived as an empty response often
  # enough to look like a parsing bug.
  defp refuse(socket, status, deadline) do
    _ = send_with_deadline(socket, "HTTP/1.1 #{status}\r\nContent-Length: 0\r\n\r\n", deadline)
    _ = :gen_tcp.shutdown(socket, :write)
    :gen_tcp.close(socket)
  end

  defp first_token(line), do: line |> String.split(" ", parts: 2) |> hd()

  # The acceptor is supervised beside the tunnel tasks. Excluding the current
  # acceptor process keeps the advertised 64-slot pool literal rather than
  # silently turning it into 63.
  defp open_tunnels do
    @tasks
    |> Task.Supervisor.children()
    |> Enum.count(&(&1 != self()))
  end
end
