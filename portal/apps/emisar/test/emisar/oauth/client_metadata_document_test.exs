defmodule Emisar.OAuth.ClientMetadataDocumentTest do
  use Emisar.DataCase, async: true
  alias Emisar.OAuth.ClientMetadataDocument

  @url "https://app.example.com/oauth/client-metadata.json"

  defmodule Resolver do
    def getaddrs(host, family, timeout) do
      %{owner: owner, resolve: resolve} = Emisar.Config.fetch_env!(:emisar, __MODULE__)
      send(owner, {:resolve, self(), host, family, timeout})
      resolve.(family)
    end
  end

  defmodule HTTP do
    def connect(scheme, address, port, opts) do
      config = Emisar.Config.fetch_env!(:emisar, __MODULE__)
      send(config.owner, {:connect, self(), scheme, address, port, opts})
      {:ok, Map.put(config, :ref, make_ref())}
    end

    def request(%{failure: :request} = conn, "GET", _path, _headers, nil),
      do: {:error, conn, :closed}

    def request(conn, "GET", path, headers, nil) do
      send(conn.owner, {:request, path, headers})
      {:ok, conn, conn.ref}
    end

    def recv(%{failure: :receive} = conn, 0, _timeout),
      do: {:error, conn, :closed, []}

    def recv(conn, 0, timeout) do
      send(conn.owner, {:recv_timeout, timeout})

      {:ok, conn,
       [
         {:status, conn.ref, conn.status},
         {:headers, conn.ref, [{"content-type", conn.content_type}]},
         {:data, conn.ref, conn.body},
         {:done, conn.ref}
       ]}
    end

    def close(conn) do
      send(conn.owner, :http_closed)
      {:ok, conn}
    end
  end

  defmodule TrustedFixtureHTTP do
    def connect(scheme, host, port, opts) do
      %{owner: owner, certfile: certfile} = Emisar.Config.fetch_env!(:emisar, __MODULE__)
      send(owner, {:tls_worker, self()})
      opts = Keyword.update!(opts, :transport_opts, &Keyword.put(&1, :cacertfile, certfile))

      with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, opts) do
        send(owner, :tls_connected)
        {:ok, conn}
      end
    end

    defdelegate request(conn, method, path, headers, body), to: Mint.HTTP
    defdelegate recv(conn, bytes, timeout), to: Mint.HTTP
    defdelegate close(conn), to: Mint.HTTP
  end

  defp document(overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => @url,
        "client_name" => "Example MCP Client",
        "redirect_uris" => ["https://app.example.com/callback"]
      },
      overrides
    )
  end

  describe "metadata_url?/1" do
    test "an https URL selects the metadata-document mechanism" do
      assert ClientMetadataDocument.metadata_url?(@url)
    end

    test "a registration id, a cleartext URL, and a non-binary do not" do
      refute ClientMetadataDocument.metadata_url?(Ecto.UUID.generate())
      refute ClientMetadataDocument.metadata_url?("http://app.example.com/client.json")
      refute ClientMetadataDocument.metadata_url?(nil)
    end
  end

  describe "fetch/1" do
    test "rejects a URL that is not https with a path, before any network work" do
      for url <- [
            "http://app.example.com/client.json",
            "https://app.example.com",
            "https://app.example.com/",
            "https://app.example.com/client.json#frag",
            "https://user:pw@app.example.com/client.json",
            "not-a-url"
          ] do
        assert ClientMetadataDocument.fetch(url) == {:error, :invalid_client_id}
      end
    end

    test "a non-binary client_id is refused" do
      assert ClientMetadataDocument.fetch(nil) == {:error, :invalid_client_id}
    end

    test "refuses a host that resolves into private space" do
      # The SSRF boundary is relaxed in the test environment so fixtures can
      # serve documents from loopback; this is the production posture.
      Emisar.Config.put_override(:emisar, ClientMetadataDocument, allow_private_hosts: false)

      for host <- [
            "localhost",
            "127.0.0.1",
            # The cloud instance-metadata address is the classic SSRF target.
            "169.254.169.254",
            "10.0.0.5",
            "[::1]",
            "[::ffff:8.8.8.8]",
            "[64:ff9b::808:808]",
            "[64:ff9b:1::808:808]",
            "[2001:2::1]",
            "[2001:20::1]",
            "[2001:db8::1]",
            "[2002:808:808::1]",
            "[2c10::1]",
            "[2d00::1]",
            "[3000::1]",
            "[3f00::1]"
          ] do
        assert ClientMetadataDocument.fetch("https://#{host}/client.json") ==
                 {:error, :blocked_destination},
               host
      end
    end

    test "pins the checked public address while retaining the original TLS hostname" do
      configure_fetch()

      assert ClientMetadataDocument.fetch(@url) == {:ok, document()}
      assert_receive {:resolve, worker, ~c"app.example.com", :inet, dns_timeout}
      assert_receive {:resolve, ^worker, ~c"app.example.com", :inet6, dns6_timeout}
      assert_receive {:connect, ^worker, :https, {8, 8, 8, 8}, 443, opts}
      assert opts[:hostname] == "app.example.com"
      assert opts[:mode] == :passive
      assert opts[:transport_opts][:send_timeout_close]
      assert opts[:transport_opts][:timeout] <= dns6_timeout
      assert dns6_timeout <= dns_timeout
      assert dns_timeout <= 5_000
      refute Keyword.has_key?(opts[:transport_opts], :verify)
      assert_receive {:request, "/oauth/client-metadata.json", headers}
      assert {"host", "app.example.com"} in headers
      assert_receive {:recv_timeout, receive_timeout}
      assert receive_timeout <= opts[:transport_opts][:timeout]
      assert_receive :http_closed
      refute_receive {:resolve, _, _, _, _}
    end

    test "a mixed public and private DNS answer never reaches HTTP" do
      configure_fetch()

      Emisar.Config.put_override(:emisar, Resolver, %{
        owner: self(),
        resolve: fn
          :inet -> {:ok, [{8, 8, 8, 8}]}
          :inet6 -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
        end
      })

      assert ClientMetadataDocument.fetch(@url) == {:error, :blocked_destination}
      refute_receive {:connect, _, _, _, _, _}
    end

    test "closes the connection on success and every response failure" do
      for {overrides, expected} <- [
            {%{}, {:ok, document()}},
            {%{failure: :request}, {:error, :document_unavailable}},
            {%{failure: :receive}, {:error, :document_unavailable}},
            {%{status: 302}, {:error, :document_unavailable}},
            {%{content_type: "text/html"}, {:error, :invalid_content_type}},
            {%{body: String.duplicate("x", 65_537)}, {:error, :document_too_large}},
            {%{body: "{"}, {:error, :invalid_document}}
          ] do
        configure_fetch(overrides)
        assert ClientMetadataDocument.fetch(@url) == expected
        assert_receive :http_closed
      end
    end

    test "bounds a DNS resolver that ignores its timeout" do
      configure_blocked_dns()
      started = System.monotonic_time(:millisecond)
      caller = Task.async(fn -> ClientMetadataDocument.fetch(@url) end)
      assert_receive {:resolve, worker, _, :inet, _}
      monitor = Process.monitor(worker)

      assert Task.await(caller, 7_000) == {:error, :document_unavailable}
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}
      assert System.monotonic_time(:millisecond) - started < 7_000
      refute_receive {:connect, _, _, _, _, _}
    end

    test "the deadline still terminates the worker when its caller disappears" do
      configure_blocked_dns()

      caller =
        Task.Supervisor.async_nolink(Emisar.TaskSupervisor, fn ->
          ClientMetadataDocument.fetch(@url)
        end)

      assert_receive {:resolve, worker, _, :inet, _}
      monitor = Process.monitor(worker)
      Task.shutdown(caller, :brutal_kill)

      assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 7_000
      refute_receive {:connect, _, _, _, _, _}
    end

    @tag :tmp_dir
    test "bounds a real TLS response that keeps delivering sub-timeout fragments", %{
      tmp_dir: tmp_dir
    } do
      {port, peer, certfile} = start_trickling_listener(tmp_dir)

      Emisar.Config.put_override(:emisar, ClientMetadataDocument,
        allow_private_hosts: true,
        http_client: TrustedFixtureHTTP
      )

      Emisar.Config.put_override(:emisar, TrustedFixtureHTTP, %{owner: self(), certfile: certfile})

      started = System.monotonic_time(:millisecond)

      assert ClientMetadataDocument.fetch("https://localhost:#{port}/client.json") ==
               {:error, :document_unavailable}

      assert_receive :tls_connected
      assert System.monotonic_time(:millisecond) - started < 7_000
      assert_receive {:tls_worker, worker}
      refute Process.alive?(worker)
      assert {:closed, chunks} = Task.await(peer, 2_000)
      assert chunks >= 3
    end
  end

  defp configure_fetch(overrides \\ %{}) do
    Emisar.Config.put_override(:emisar, ClientMetadataDocument,
      allow_private_hosts: false,
      resolver: Resolver,
      http_client: HTTP
    )

    Emisar.Config.put_override(:emisar, Resolver, %{
      owner: self(),
      resolve: fn
        :inet -> {:ok, [{8, 8, 8, 8}]}
        :inet6 -> {:error, :nxdomain}
      end
    })

    Emisar.Config.put_override(
      :emisar,
      HTTP,
      Map.merge(
        %{
          owner: self(),
          status: 200,
          content_type: "application/json",
          body: Jason.encode!(document())
        },
        overrides
      )
    )
  end

  defp configure_blocked_dns do
    configure_fetch()

    Emisar.Config.put_override(:emisar, Resolver, %{
      owner: self(),
      resolve: fn _family ->
        receive do
          :release -> {:ok, [{8, 8, 8, 8}]}
        end
      end
    })
  end

  defp start_trickling_listener(tmp_dir) do
    certfile = Path.join(tmp_dir, "metadata.pem")
    keyfile = Path.join(tmp_dir, "metadata-key.pem")
    csrfile = Path.join(tmp_dir, "metadata.csr")
    cacertfile = Path.join(tmp_dir, "ca.pem")
    cakeyfile = Path.join(tmp_dir, "ca-key.pem")

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-noenc",
          "-days",
          "1",
          "-subj",
          "/CN=Metadata Test CA",
          "-addext",
          "basicConstraints=critical,CA:TRUE",
          "-keyout",
          cakeyfile,
          "-out",
          cacertfile
        ],
        stderr_to_stdout: true
      )

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-newkey",
          "rsa:2048",
          "-noenc",
          "-subj",
          "/CN=localhost",
          "-addext",
          "subjectAltName=DNS:localhost",
          "-keyout",
          keyfile,
          "-out",
          csrfile
        ],
        stderr_to_stdout: true
      )

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csrfile,
          "-CA",
          cacertfile,
          "-CAkey",
          cakeyfile,
          "-CAcreateserial",
          "-days",
          "1",
          "-copy_extensions",
          "copy",
          "-out",
          certfile
        ],
        stderr_to_stdout: true
      )

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        active: false,
        reuseaddr: true,
        packet: :raw
      ])

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_address, port}} = :ssl.sockname(listener)

    peer =
      Task.async(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 5_000)

        case :ssl.handshake(transport, 5_000) do
          {:error, reason} ->
            {:handshake_failed, reason}

          {:ok, socket} ->
            {:ok, _request} = :ssl.recv(socket, 0, 5_000)

            :ok =
              :ssl.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
              )

            :ok = :ssl.setopts(socket, active: true)
            send(self(), :chunk)
            trickle(socket, 0)
        end
      end)

    {port, peer, String.to_charlist(cacertfile)}
  end

  defp trickle(socket, chunks) do
    receive do
      :chunk ->
        case :ssl.send(socket, "1\r\n \r\n") do
          :ok ->
            Process.send_after(self(), :chunk, 200)
            trickle(socket, chunks + 1)

          {:error, :closed} ->
            {:closed, chunks}
        end

      {:ssl_closed, ^socket} ->
        {:closed, chunks}
    after
      8_000 -> flunk("metadata client left its TLS socket open")
    end
  end

  describe "validate/2" do
    test "accepts a document that matches its URL and carries the required fields" do
      assert ClientMetadataDocument.validate(document(), @url) == {:ok, document()}
    end

    test "rejects a document claiming a client_id other than its own URL" do
      impostor = document(%{"client_id" => "https://victim.example.com/client.json"})

      assert ClientMetadataDocument.validate(impostor, @url) == {:error, :client_id_mismatch}
    end

    test "requires client_id, client_name, and redirect_uris to be present" do
      for field <- ~w(client_id client_name redirect_uris) do
        incomplete = Map.delete(document(), field)

        assert ClientMetadataDocument.validate(incomplete, @url) ==
                 {:error, :missing_required_fields}
      end
    end
  end
end
