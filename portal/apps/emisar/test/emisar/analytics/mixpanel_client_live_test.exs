defmodule Emisar.Analytics.MixpanelClient.LiveTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Emisar.Analytics.MixpanelClient.Live

  setup do
    Emisar.Config.put_override(:emisar, :mixpanel_token, "test-token")
  end

  test "returns an error instead of raising when a payload cannot be encoded" do
    assert {:error, {:encode, _reason}} =
             Live.track([%{"properties" => %{"unencodable" => self()}}])
  end

  test "an HTTP 200 whose body is 1 is accepted" do
    serve_once("1")
    assert Live.track([%{"event" => "signed_in", "properties" => %{}}]) == :ok
  end

  test "an HTTP 200 whose body is 0 is a rejected batch, logged without the payload" do
    # Mixpanel's ingestion endpoints answer 200 even when they reject every
    # object; only the body says so.
    serve_once("0")

    log =
      capture_log(fn ->
        assert Live.engage([%{"$distinct_id" => "secret-member-id"}]) == {:error, :rejected}
      end)

    assert log =~ "mixpanel /engage rejected every object in the batch"
    refute log =~ "secret-member-id"
  end

  defp serve_once(body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    Emisar.Config.put_override(:emisar, :mixpanel_api_host, "http://127.0.0.1:#{port}")

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

      :gen_tcp.close(socket)
    end)
  end
end
