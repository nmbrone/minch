defmodule MinchTest do
  use ExUnit.Case

  defmodule Server do
    use Minch.TestServer

    def send_frame(server, frame) do
      send(server, {:send_frame, frame})
      :ok
    end

    def init(req, state) do
      send(state.receiver, {:ws_server_req, req})
      {:cowboy_websocket, req, state}
    end

    def websocket_init(state) do
      send(state.receiver, {:ws_server_init, self()})
      {[], state}
    end

    def websocket_handle(frame, state) do
      send(state.receiver, {:ws_server_frame, frame})
      {[], state}
    end

    def websocket_info({:send_frame, frame}, state) do
      {List.wrap(frame), state}
    end

    def terminate(reason, _req, state) do
      send(state.receiver, {:ws_server_terminate, reason})
      :ok
    end
  end

  defmodule Client do
    use Minch

    def start_link(state) do
      Minch.start_link(__MODULE__, state, name: __MODULE__)
    end

    def connect(state) do
      state.url
    end

    def init(state) do
      send(state.receiver, {:ws_client_init, state})
      {:ok, state}
    end

    def terminate(reason, state) do
      send(state.receiver, {:ws_client_terminate, reason})
      :ok
    end

    def handle_connect(state) do
      send(state.receiver, {:ws_client_connect, state})
      {:reply, :ping, state}
    end

    def handle_disconnect(reason, state) do
      send(state.receiver, {:ws_client_disconnect, reason})
      {:reconnect, 50, state}
    end

    def handle_info(message, state) do
      send(state.receiver, {:ws_client_info, message})
      {:noreply, state}
    end

    def handle_frame(frame, state) do
      send(state.receiver, {:ws_client_frame, frame})

      case frame do
        {:ping, data} -> {:reply, {:pong, data}, state}
        _ -> {:ok, state}
      end
    end
  end

  setup do
    port = 8881
    start_link_supervised!({Server, state: %{receiver: self()}, port: port})
    [url: "ws://localhost:#{port}"]
  end

  describe "client" do
    setup %{url: url} do
      pid = start_link_supervised!({Client, %{receiver: self(), url: url}})
      [client: pid]
    end

    test "callbacks", %{client: client} do
      assert_receive {:ws_server_init, server}

      # init
      assert_receive {:ws_client_init, _}

      # handle_connect
      assert_receive {:ws_client_connect, _}

      # reply from handle_connect
      assert_receive {:ws_server_frame, :ping}

      # handle_frame
      :ok = Server.send_frame(server, :pong)
      assert_receive {:ws_client_frame, {:pong, ""}}

      # reply from handle_frame
      :ok = Server.send_frame(server, :ping)
      assert_receive {:ws_server_frame, :pong}

      # handle_info
      send(client, "123")
      assert_receive {:ws_client_info, "123"}

      # handle_disconnect
      :ok = Server.send_frame(server, :close)
      assert_receive {:ws_client_disconnect, %Mint.TransportError{reason: :closed}}

      # reconnect from handle_disconnect
      assert_receive {:ws_client_connect, _}

      # terminate
      stop_supervised!(Client)
      assert_receive {:ws_client_terminate, :shutdown}

      # properly closes the connection on terminate
      assert_receive {:ws_server_terminate, :remote}
    end
  end

  describe "simple client" do
    test "returns the connection error" do
      assert {:error, %Mint.TransportError{reason: :econnrefused}} =
               Minch.connect("ws://localhost:8000")
    end

    test "sends headers to the server while connecting", %{url: url} do
      {:ok, _pid, _ref} = Minch.connect(url, [{"x-hello", "world"}])
      assert_receive {:ws_server_req, %{headers: %{"x-hello" => "world"}}}
    end

    test "sends frames to the server", %{url: url} do
      {:ok, pid, _ref} = Minch.connect(url)
      :ok = Minch.send_frame(pid, :ping)
      assert_receive {:ws_server_frame, :ping}
    end

    test "sends received frames to the parent process", %{url: url} do
      {:ok, _pid, ref} = Minch.connect(url)
      assert_receive {:ws_server_init, server}
      :ok = Server.send_frame(server, :ping)
      assert_receive {:frame, ^ref, {:ping, ""}}
    end

    test "properly closes the connection", %{url: url} do
      {:ok, pid, _ref} = Minch.connect(url)
      :ok = Minch.close(pid)
      assert_receive {:ws_server_terminate, :remote}
    end

    test "properly closes the connection when the parent process dies", %{url: url} do
      Task.start(fn ->
        {:ok, _pid, _ref} = Minch.connect(url)
      end)

      assert_receive {:ws_server_terminate, :remote}
    end

    test "terminates when the server closes the connection", %{url: url} do
      {:ok, pid, ref} = Minch.connect(url)
      Process.monitor(pid)
      assert_receive {:ws_server_init, server}
      :ok = Server.send_frame(server, :close)
      assert_receive {:frame, ^ref, {:close, 1000, ""}}

      assert_receive {:DOWN, _ref, :process, ^pid,
                      {:shutdown, %Mint.TransportError{reason: :closed}}}
    end
  end
end
