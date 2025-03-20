defmodule Minch.ClientTest do
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

  defmodule Client do
    use Minch

    def start_link(state) do
      Minch.start_link(__MODULE__, state)
    end

    def connect(state) do
      send(state.receiver, {:client, :connect, [state]})
      state.url
    end

    def init(state) do
      send(state.receiver, {:client, :init, [state]})
      {:ok, state}
    end

    def terminate(reason, state) do
      send(state.receiver, {:client, :terminate, [reason, state]})
      :ok
    end

    def handle_connect(response, state) do
      send(state.receiver, {:client, :handle_connect, [response, state]})
      {:reply, :ping, state}
    end

    def handle_disconnect(reason, attempt, state) do
      send(state.receiver, {:client, :handle_disconnect, [reason, attempt, state]})
      {:reconnect, 50, state}
    end

    def handle_info(message, state) do
      send(state.receiver, {:client, :handle_info, [message, state]})
      {:ok, state}
    end

    def handle_frame(frame, state) do
      send(state.receiver, {:client, :handle_frame, [frame, state]})
      {:ok, state}
    end
  end

  setup do
    port = 8881
    url = "ws://localhost:#{port}"
    start_link_supervised!({Server, state: %{receiver: self()}, port: port})
    client = start_link_supervised!({Client, %{receiver: self(), url: url}})
    assert_receive {:server, :init, server}
    [client: client, server: server, url: url]
  end

  test "connect/1 is called before connecting" do
    assert_receive {:client, :connect, [_state]}
    assert_receive {:client, :init, [_state]}
  end

  test "handle_connect/2 is called after connecting" do
    assert_receive {:client, :handle_connect, [%{status: 101, headers: _}, _state]}
  end

  test "handle_disconnect/2 is called after connection failed" do
    Client.start_link(%{receiver: self(), url: "ws://example.test"})

    assert_receive {:client, :handle_disconnect,
                    [%Mint.TransportError{reason: :nxdomain}, 1, _state]}

    assert_receive {:client, :handle_disconnect,
                    [%Mint.TransportError{reason: :nxdomain}, 2, _state]}
  end

  test "replies from a callback" do
    assert_receive {:server, :frame, :ping}
  end

  test "sends pong to server ping automatically", ctx do
    assert_receive {:client, :handle_connect, _}
    :ok = Server.send_frame(ctx.server, {:ping, "123"})
    assert_receive {:server, :frame, {:pong, "123"}}
  end

  test "handle_frame/2 is called with all frames", ctx do
    assert_receive {:client, :handle_connect, _}
    Server.send_frame(ctx.server, {:text, "hello"})
    Server.send_frame(ctx.server, {:binary, <<>>})
    Server.send_frame(ctx.server, {:pong, "123"})
    assert_receive {:client, :handle_frame, [{:text, "hello"}, _state]}
    assert_receive {:client, :handle_frame, [{:binary, <<>>}, _state]}
    assert_receive {:client, :handle_frame, [{:pong, "123"}, _state]}
  end

  test "handle_info/2 is called with an arbitrary message", ctx do
    send(ctx.client, "hello")
    assert_receive {:client, :handle_info, ["hello", _state]}
  end

  test "handle_disconnect/2 is called when received a :close frame from server", ctx do
    assert_receive {:client, :handle_connect, _}
    :ok = Server.send_frame(ctx.server, :close)
    assert_receive {:client, :handle_disconnect, [{:close, 1000, <<>>}, 0, _state]}
  end

  test "connection is properly closed and terminate/2 is called" do
    assert_receive {:client, :handle_connect, _}
    stop_supervised!(Client)
    assert_receive {:server, :terminate, :remote}
    assert_receive {:client, :terminate, [:shutdown, _state]}
  end

  test "returns an error if the frame can't be sent", ctx do
    {:ok, pid} = Client.start_link(%{receiver: self(), url: ctx.url})

    assert {:error, %Minch.Conn.NotUpgradedError{}} =
             Minch.send_frame(pid, {:text, "hello"})
  end

  test "closes the connection by sending a :close frame to the server", ctx do
    assert_receive {:client, :handle_connect, _}
    assert :ok = Minch.send_frame(ctx.client, :close)
    assert_receive {:server, :terminate, :remote}
    assert_receive {:client, :handle_disconnect, [{:close, 1000, <<>>}, 0, _state]}
  end
end
