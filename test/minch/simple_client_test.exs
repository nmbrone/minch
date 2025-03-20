defmodule Minch.SimpleClientTest do
  use ExUnit.Case, async: true

  setup ctx do
    port = 8882
    server_state = Map.merge(%{receiver: self(), connect_result: :ok}, ctx[:server_state] || %{})
    start_link_supervised!({Server, state: server_state, port: port})
    [url: "ws://localhost:#{port}"]
  end

  test "returns the connection error" do
    assert {:error, %Mint.TransportError{reason: :nxdomain}} = Minch.connect("ws://example.test")
  end

  @tag server_state: %{connect_result: :timeout}
  test "handles the connection timeout", %{url: url} do
    {:error, :timeout} = Minch.connect(url, [], transport_opts: [timeout: 100])
  end

  test "sends headers to the server while connecting", %{url: url} do
    {:ok, _pid, _ref} = Minch.connect(url, [{"x-hello", "world"}])
    assert_receive {:server, :connect, conn}
    assert Plug.Conn.get_req_header(conn, "x-hello") == ["world"]
  end

  test "sends frames to the server", %{url: url} do
    {:ok, pid, _ref} = Minch.connect(url)
    :ok = Minch.send_frame(pid, :ping)
    assert_receive {:server, :frame, {:ping, ""}}
  end

  test "sends received frames to the parent process", %{url: url} do
    {:ok, _pid, ref} = Minch.connect(url)
    assert_receive {:server, :init, server}
    Server.send_frame(server, {:text, "hello"})
    assert {:text, "hello"} = Minch.receive_frame(ref)
  end

  test "gracefully closes the connection when terminating", %{url: url} do
    {:ok, pid, _ref} = Minch.connect(url)
    :ok = Minch.close(pid)
    assert_receive {:server, :terminate, :remote}
  end

  test "gracefully closes the connection when the parent process dies", %{url: url} do
    {:ok, pid} =
      Task.start(fn ->
        {:ok, _pid, _ref} = Minch.connect(url)
        receive(do: (:stop -> exit(:normal)))
      end)

    assert_receive {:server, :init, _server}
    send(pid, :stop)
    assert_receive {:server, :terminate, :remote}
  end

  test "terminates when the server closes the connection", %{url: url} do
    {:ok, pid, _ref} = Minch.connect(url)
    monitor_ref = Process.monitor(pid)
    assert_receive {:server, :init, server}
    Server.close(server)
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, {:shutdown, _}}
  end
end
