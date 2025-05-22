defmodule Minch.SimpleClientTest do
  use ExUnit.Case, async: true

  defmodule Server do
    use Minch.TestServer

    def send_frame(server, frame) do
      send(server, {:send_frame, frame})
      :ok
    end

    def init(req, state) do
      send(state.receiver, {:server, :request, req})
      {:cowboy_websocket, req, state}
    end

    def websocket_init(state) do
      send(state.receiver, {:server, :init, self()})
      {[], state}
    end

    def websocket_handle(frame, state) do
      send(state.receiver, {:server, :frame, frame})
      {[], state}
    end

    def websocket_info({:send_frame, frame}, state) do
      {List.wrap(frame), state}
    end

    def terminate(reason, _req, state) do
      send(state.receiver, {:server, :terminate, reason})
      :ok
    end
  end

  setup do
    port = 8882
    start_link_supervised!({Server, state: %{receiver: self()}, port: port})
    [url: "ws://localhost:#{port}"]
  end

  test "returns the connection error" do
    assert {:error, %Mint.TransportError{reason: :nxdomain}} = Minch.connect("ws://example.test")
  end

  test "sends headers to the server while connecting", %{url: url} do
    {:ok, _pid, _ref} = Minch.connect(url, [{"x-hello", "world"}])
    assert_receive {:server, :request, %{headers: %{"x-hello" => "world"}}}
  end

  test "sends frames to the server", %{url: url} do
    {:ok, pid, _ref} = Minch.connect(url)
    :ok = Minch.send_frame(pid, :ping)
    assert_receive {:server, :frame, :ping}
  end

  test "sends received frames to the parent process", %{url: url} do
    {:ok, _pid, ref} = Minch.connect(url)
    assert_receive {:server, :init, server}
    :ok = Server.send_frame(server, {:text, "hello"})
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
    :ok = Server.send_frame(server, {:close, 1000, "test"})
    assert_receive {:DOWN, ^monitor_ref, :process, _pid, {:shutdown, {:close, 1000, "test"}}}
  end
end
