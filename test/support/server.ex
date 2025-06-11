defmodule Server do
  use Minch.TestServer

  # https://ninenines.eu/docs/en/cowboy/2.13/manual/cowboy_websocket/

  def send_frame(server, frame) do
    send(server, {:send_frame, frame})
    :ok
  end

  def close(server) do
    send(server, :close)
    :ok
  end

  def connect(conn, state) do
    send(state.receiver, {:server, :connect, conn})

    case state.connect_result do
      :ok ->
        {conn, state}

      :timeout ->
        send(state.receiver, {:server, :init, nil})
        Process.sleep(:infinity)

      :unauthorized ->
        send(state.receiver, {:server, :init, nil})
        {conn |> Plug.Conn.send_resp(401, "Unauthorized") |> Plug.Conn.halt(), state}
    end
  end

  def init(state) do
    send(state.receiver, {:server, :init, self()})
    {:ok, state}
  end

  def terminate(reason, state) do
    send(state.receiver, {:server, :terminate, reason})
    :ok
  end

  def handle_in(message, state) do
    send(state.receiver, {:server, :frame, to_frame(message)})
    {:ok, state}
  end

  def handle_control(message, state) do
    send(state.receiver, {:server, :frame, to_frame(message)})
    {:ok, state}
  end

  def handle_info({:send_frame, frame}, state) do
    {:push, frame, state}
  end

  def handle_info(:close, state) do
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    send(state.receiver, {:server, :handle_info, [message, state]})
    {:ok, state}
  end

  defp to_frame({data, [opcode: code]}) do
    {code, data}
  end
end
