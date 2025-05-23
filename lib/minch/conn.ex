defmodule Minch.Conn do
  @moduledoc false
  use GenServer

  alias __MODULE__, as: State

  defstruct [
    :conn,
    :conn_attempt,
    :request_ref,
    :response_status,
    :websocket,
    :callback,
    :callback_state,
    :reconnect_timer
  ]

  @internal :"$minch"

  @spec start_link(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start_link(module, init_arg, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, init_arg}, opts)
  end

  @spec start(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start(module, init_arg, opts \\ []) do
    GenServer.start(__MODULE__, {module, init_arg}, opts)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(conn) do
    GenServer.stop(conn)
  end

  @impl true
  def init({callback, init_arg}) do
    case callback.init(init_arg) do
      {:ok, callback_state} ->
        state = %State{callback: callback, callback_state: callback_state, conn_attempt: 0}
        Process.flag(:trap_exit, true)
        {:ok, state, {:continue, :connect}}

      {:error, reason} ->
        {:error, reason}

      :ignore ->
        :ignore
    end
  end

  @impl true
  def terminate(reason, %State{} = state) do
    if state.websocket, do: send_frame(state, :close)
    if state.conn, do: Mint.HTTP.close(state.conn)
    state.callback.terminate(reason, state.callback_state)
  end

  @impl true
  def handle_continue(:connect, %State{} = state) do
    {url, headers, options} =
      case state.callback.connect(state.callback_state) do
        {url, headers, options} -> {url, headers, options}
        {url, headers} -> {url, headers, []}
        url -> {url, [], []}
      end

    url = URI.parse(url)

    path =
      case url.path do
        nil -> "/"
        path -> path
      end

    path =
      case url.query do
        nil -> path
        query -> path <> "?" <> query
      end

    {http_scheme, ws_scheme} =
      case url.scheme do
        "wss" -> {:https, :wss}
        "ws" -> {:http, :ws}
      end

    {upgrade_opts, connect_opts} =
      options
      # set protocol to HTTP1 by default since WebSocket over HTTP2 is barely supported
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.split([:extension])

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, url.host, url.port, connect_opts),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, upgrade_opts) do
      {:noreply, %{state | conn: conn, conn_attempt: 1, request_ref: ref}}
    else
      {:error, error} ->
        handle_disconnect(error, %{state | conn_attempt: state.conn_attempt + 1})

      {:error, conn, error} ->
        {:ok, conn} = Mint.HTTP.close(conn)
        handle_disconnect(error, %{state | conn_attempt: state.conn_attempt + 1, conn: conn})
    end
  end

  @impl true
  def handle_call({:send_frame, _frame}, _from, %State{websocket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_frame, frame}, _from, state) do
    case send_frame(state, frame) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({@internal, {:handle_response, msg}}, state) do
    handle_response(msg, state)
  end

  def handle_info({@internal, {:handle_frame, frame}}, state) do
    handle_frame(frame, state)
  end

  def handle_info({@internal, {:send_frame, frame}}, state) do
    case send_frame(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, state, error} -> handle_error(error, state)
    end
  end

  def handle_info({@internal, :reconnect}, %State{} = state) do
    {:noreply, %{state | reconnect_timer: nil}, {:continue, :connect}}
  end

  def handle_info(message, %State{} = state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        for msg <- responses, do: internal_event({:handle_response, msg})
        {:noreply, %{state | conn: conn}}

      {:error, conn, error, _responses} ->
        {:ok, conn} = Mint.HTTP.close(conn)
        handle_disconnect(error, %{state | conn: conn})

      :unknown ->
        callback(state, :handle_info, [message, state.callback_state])
    end
  end

  defp handle_response({:data, _, _}, %State{websocket: nil} = state) do
    {:noreply, state}
  end

  defp handle_response({:data, ref, data}, %State{request_ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        for frame <- frames, do: internal_event({:handle_frame, frame})
        {:noreply, %{state | websocket: websocket}}

      {:error, websocket, error} ->
        handle_error({:decode_frame, error}, %{state | websocket: websocket})
    end
  end

  defp handle_response({:status, ref, status}, %State{request_ref: ref} = state) do
    {:noreply, %{state | response_status: status}}
  end

  defp handle_response({:headers, ref, headers}, %State{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.response_status, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        response = %{status: state.response_status, headers: headers}
        callback(state, :handle_connect, [response, state.callback_state])

      {:error, conn, error} ->
        {:ok, conn} = Mint.HTTP.close(conn)
        handle_disconnect(error, %{state | conn: conn})
    end
  end

  defp handle_response({:error, ref, error}, %State{request_ref: ref} = state) do
    handle_error({:response, error}, state)
  end

  defp handle_response({:done, ref}, %State{request_ref: ref} = state) do
    {:noreply, state}
  end

  defp handle_frame({:close, _, _} = frame, %State{} = state) do
    {:ok, conn} = Mint.HTTP.close(state.conn)
    handle_disconnect(frame, %{state | conn: conn})
  end

  defp handle_frame({:ping, data}, %State{} = state) do
    internal_event({:send_frame, {:pong, data}})
    {:noreply, state}
  end

  defp handle_frame(frame, %State{} = data) do
    callback(data, :handle_frame, [frame, data.callback_state])
  end

  defp handle_disconnect(error, %State{} = state) do
    case state.callback.handle_disconnect(error, state.conn_attempt, state.callback_state) do
      {:reconnect, backoff, callback_state} ->
        if timer = state.reconnect_timer, do: Process.cancel_timer(timer)
        timer = internal_event(:reconnect, backoff)
        {:noreply, %{state | callback_state: callback_state, reconnect_timer: timer}}

      {:stop, reason, callback_state} ->
        {:stop, reason, %{state | callback_state: callback_state}}
    end
  end

  defp handle_error(error, %State{} = state) do
    callback(state, :handle_error, [error, state.callback_state])
  end

  defp callback(%State{} = state, name, args) do
    case apply(state.callback, name, args) do
      {:ok, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}}

      {:reply, frames, callback_state} ->
        for frame <- List.wrap(frames), do: internal_event({:send_frame, frame})
        {:noreply, %{state | callback_state: callback_state}}

      {:stop, reason, callback_state} ->
        {:stop, reason, %{state | callback_state: callback_state}}
    end
  end

  defp send_frame(%State{} = state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, bin} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, bin) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, error} ->
            {:error, %{state | conn: conn, websocket: websocket}, error}
        end

      {:error, websocket, error} ->
        {:error, %{state | websocket: websocket}, error}
    end
  end

  defp internal_event(message) do
    send(self(), {@internal, message})
  end

  defp internal_event(message, delay) do
    Process.send_after(self(), {@internal, message}, delay)
  end
end
