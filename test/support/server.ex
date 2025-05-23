defmodule Server do
  use Minch.TestServer

  # https://ninenines.eu/docs/en/cowboy/2.13/manual/cowboy_websocket/

  def send_frame(server, frame) do
    send(server, {:send_frame, frame})
    :ok
  end

  def init(req, state) do
    send(state.receiver, {:server, :request, req})

    case state.init_result do
      :ok ->
        {:cowboy_websocket, req, state}

      :unauthorized ->
        send(state.receiver, {:server, :init, nil})
        req = :cowboy_req.reply(401, %{}, "Unauthorized", req)
        {:ok, req, state}

      :timeout ->
        send(state.receiver, {:server, :init, nil})
        Process.sleep(:infinity)
    end
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
