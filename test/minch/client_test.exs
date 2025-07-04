defmodule Minch.ClientTest do
  use ExUnit.Case, async: true

  defmodule Client do
    use Minch, restart: :transient

    def start_link(state) do
      Minch.start_link(__MODULE__, state)
    end

    def connect(state) do
      send(state.receiver, {:client, :connect, [state]})
      {state.url, state[:headers] || [], state[:options] || []}
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
      {:ok, state}
    end

    def handle_disconnect(reason, attempt, state) do
      send(state.receiver, {:client, :handle_disconnect, [reason, attempt, state]})

      case state[:reconnect] do
        nil -> {:stop, :normal, state}
        backoff -> {:reconnect, backoff, state}
      end
    end

    def handle_info(message, state) do
      send(state.receiver, {:client, :handle_info, [message, state]})

      case message do
        {:reply, frame} -> {:reply, frame, state}
        {:close, code, reason} -> {:close, code, reason, state}
        {:stop, reason} -> {:stop, reason, state}
        _ -> {:ok, state}
      end
    end

    def handle_frame(frame, state) do
      send(state.receiver, {:client, :handle_frame, [frame, state]})
      {:ok, state}
    end
  end

  setup ctx do
    port = 8881
    url = "ws://localhost:#{port}"

    server_state = Map.merge(%{receiver: self(), init_result: :ok}, ctx[:server_state] || %{})
    start_link_supervised!({Server, state: server_state, port: port})

    client_state = Map.merge(%{receiver: self(), url: url}, ctx[:client_state] || %{})
    client = start_link_supervised!({Client, client_state})

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

  @tag server_state: %{init_result: :unauthorized}
  @tag client_state: %{reconnect: 1000}
  test "handle_disconnect/2 is called after upgrading error" do
    assert_receive {:client, :handle_disconnect,
                    [%Mint.WebSocket.UpgradeFailureError{status_code: 401}, 1, _]}
  end

  test "handle_disconnect/2 is called after connection failed" do
    Client.start_link(%{receiver: self(), url: "ws://example.test", reconnect: 50})

    assert_receive {:client, :handle_disconnect,
                    [%Mint.TransportError{reason: :nxdomain}, 1, _state]}

    assert_receive {:client, :handle_disconnect,
                    [%Mint.TransportError{reason: :nxdomain}, 2, _state]}
  end

  test "replies from a callback", ctx do
    assert_receive {:client, :handle_connect, _}
    send(ctx.client, {:reply, :ping})
    assert_receive {:server, :frame, :ping}
  end

  test "sends pong to server ping automatically", ctx do
    assert_receive {:client, :handle_connect, _}
    Server.send_frame(ctx.server, {:ping, "123"})
    assert_receive {:server, :frame, {:pong, "123"}}
  end

  test "handle_frame/2 is called with all frames", ctx do
    assert_receive {:client, :handle_connect, _}
    Server.send_frame(ctx.server, {:text, "hello"})
    Server.send_frame(ctx.server, {:binary, ""})
    Server.send_frame(ctx.server, {:pong, "123"})
    assert_receive {:client, :handle_frame, [{:text, "hello"}, _state]}
    assert_receive {:client, :handle_frame, [{:binary, ""}, _state]}
    assert_receive {:client, :handle_frame, [{:pong, "123"}, _state]}
  end

  test "handle_info/2 is called with an arbitrary message", ctx do
    send(ctx.client, "hello")
    assert_receive {:client, :handle_info, ["hello", _state]}
  end

  test "handle_disconnect/2 is called when received a :close frame from server", ctx do
    assert_receive {:client, :handle_connect, _}
    Server.send_frame(ctx.server, :close)
    assert_receive {:client, :handle_disconnect, _}
  end

  test "connection is properly closed and terminate/2 is called", ctx do
    assert_receive {:client, :handle_connect, _}
    Minch.close(ctx.client)
    assert_receive {:server, :terminate, :remote}
    assert_receive {:client, :terminate, [:normal, _state]}
  end

  test "returns an error if the frame can't be sent", ctx do
    {:ok, pid} = Client.start_link(%{receiver: self(), url: ctx.url})
    assert {:error, :not_connected} = Minch.send_frame(pid, {:text, "hello"})
  end

  test "gracefully closes the connection by returning a :close tuple from a callback", ctx do
    assert_receive {:client, :handle_connect, _}
    send(ctx.client, {:close, 1000, "bye"})
    assert_receive {:server, :terminate, {:remote, 1000, "bye"}}
    assert_receive {:client, :handle_disconnect, [%Mint.TransportError{reason: :closed}, 1, _]}
  end

  test "stops the client process by returning a :stop tuple from a callback", ctx do
    assert_receive {:client, :handle_connect, _}
    send(ctx.client, {:stop, :normal})
    assert_receive {:server, :terminate, :remote}
    assert_receive {:client, :terminate, [:normal, _]}
  end
end
