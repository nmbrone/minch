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
    :reconnect_timer,
    :close_timer,
    :close_frame,
    :close_timeout
  ]

  @options [:close_timeout]
  @internal :"$minch"

  @spec start_link(module(), term(), [Minch.option()]) :: GenServer.on_start()
  def start_link(module, init_arg, opts \\ []) do
    {opts, gen_opts} = Keyword.split(opts, @options)
    GenServer.start_link(__MODULE__, {module, init_arg, opts}, gen_opts)
  end

  @spec start(module(), term(), [Minch.option()]) :: GenServer.on_start()
  def start(module, init_arg, opts \\ []) do
    {opts, gen_opts} = Keyword.split(opts, @options)
    GenServer.start(__MODULE__, {module, init_arg, opts}, gen_opts)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(conn) do
    GenServer.stop(conn)
  end

  @impl true
  def init({callback, init_arg, opts}) do
    case callback.init(init_arg) do
      {:ok, callback_state} ->
        state = %State{
          callback: callback,
          callback_state: callback_state,
          close_timeout: Keyword.get(opts, :close_timeout, 5000),
          conn_attempt: 0
        }

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
    state = state |> send_frame(:close) |> discard_error() |> close()
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

    case connect(url, headers, options) do
      {:ok, conn, ref} ->
        {:noreply, %{state | conn: conn, request_ref: ref}}

      {:error, error} ->
        handle_disconnect(error, state)

      {:error, conn, error} ->
        handle_disconnect(error, %{state | conn: conn})
    end
  end

  @impl true
  def handle_call({:send_frame, frame}, _from, state) do
    case send_frame(state, frame) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info({@internal, {:send_frame, frame}}, state) do
    state |> send_frame(frame) |> handle_send()
  end

  def handle_info({@internal, :reconnect}, %State{} = state) do
    {:noreply, %{state | reconnect_timer: nil}, {:continue, :connect}}
  end

  def handle_info({@internal, :close_timeout}, %State{close_timer: nil} = state) do
    {:noreply, state}
  end

  def handle_info({@internal, :close_timeout}, state) do
    handle_disconnect(state.close_frame, state)
  end

  def handle_info(message, %State{conn: nil} = state) do
    callback(state, :handle_info, [message, state.callback_state])
  end

  def handle_info(message, %State{} = state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_each(responses, %{state | conn: conn}, &handle_response/2)

      {:error, conn, error, _responses} ->
        handle_disconnect(error, %{state | conn: conn})

      :unknown ->
        callback(state, :handle_info, [message, state.callback_state])
    end
  end

  defp handle_each([], state, _fun), do: {:noreply, state}

  defp handle_each([item | rest], state, fun) do
    case fun.(item, state) do
      {:noreply, state} -> handle_each(rest, state, fun)
      {:stop, _, _} = stop -> stop
    end
  end

  defp handle_response({:data, _, _}, %State{websocket: nil} = state) do
    {:noreply, state}
  end

  defp handle_response({:data, ref, data}, %State{request_ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        handle_each(frames, %{state | websocket: websocket}, &handle_frame/2)

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
        state = %{state | conn: conn, websocket: websocket, conn_attempt: 0}
        response = %{status: state.response_status, headers: headers}
        callback(state, :handle_connect, [response, state.callback_state])

      {:error, conn, error} ->
        handle_disconnect(error, %{state | conn: conn})
    end
  end

  defp handle_response({:error, ref, error}, %State{request_ref: ref} = state) do
    handle_error({:response, error}, state)
  end

  defp handle_response({:done, _ref}, state) do
    {:noreply, state}
  end

  # the server initiated close
  defp handle_frame({:close, _, _} = frame, %State{close_frame: nil} = state) do
    state = state |> stream_frame(frame) |> discard_error()
    handle_disconnect(frame, state)
  end

  # the server answered our close frame
  defp handle_frame({:close, _, _}, %State{} = state) do
    handle_disconnect(state.close_frame, state)
  end

  # a ping must be answered even after we have sent a close frame
  defp handle_frame({:ping, data}, %State{} = state) do
    state |> stream_frame({:pong, data}) |> handle_send()
  end

  defp handle_frame(frame, %State{} = data) do
    callback(data, :handle_frame, [frame, data.callback_state])
  end

  defp handle_disconnect(error, %State{} = state) do
    reason = state.close_frame || error
    state = close(%{state | conn_attempt: state.conn_attempt + 1})

    case state.callback.handle_disconnect(reason, state.conn_attempt, state.callback_state) do
      {:reconnect, backoff, callback_state} ->
        cancel_timer(state.reconnect_timer)
        reconnect_timer = internal_event(:reconnect, backoff)
        {:noreply, %{state | callback_state: callback_state, reconnect_timer: reconnect_timer}}

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

      {:close, code, reason, callback_state} ->
        %{state | callback_state: callback_state}
        |> send_close({:close, code, reason})
        |> handle_close()

      {:stop, reason, callback_state} ->
        {:stop, reason, %{state | callback_state: callback_state}}
    end
  end

  defp handle_send({:ok, state}), do: {:noreply, state}
  defp handle_send({:error, state, error}), do: handle_error(error, state)

  defp handle_close({:ok, state}), do: {:noreply, state}
  defp handle_close({:error, state, :not_connected}), do: {:noreply, state}
  defp handle_close({:error, state, :closing}), do: {:noreply, state}
  defp handle_close({:error, state, error}), do: handle_disconnect(error, state)

  defp discard_error({:ok, state}), do: state
  defp discard_error({:error, state, _error}), do: state

  defp send_frame(state, {:close, _, _} = frame), do: send_close(state, frame)
  defp send_frame(state, :close = frame), do: send_close(state, frame)
  defp send_frame(%State{close_frame: nil} = state, frame), do: stream_frame(state, frame)
  defp send_frame(state, _frame), do: {:error, state, :closing}

  defp stream_frame(%State{websocket: nil} = state, _frame) do
    {:error, state, :not_connected}
  end

  defp stream_frame(%State{websocket: websocket} = state, frame) do
    case Mint.WebSocket.encode(websocket, frame) do
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

  defp connect(url, headers, options) do
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

    {upgrade_opts, connect_opts} =
      options
      # set protocol to HTTP1 by default since WebSocket over HTTP2 is barely supported
      |> Keyword.put_new(:protocols, [:http1])
      |> Keyword.split([:extensions])

    with {:ok, http_scheme, ws_scheme} <- schemes(url.scheme),
         {:ok, conn} <- Mint.HTTP.connect(http_scheme, url.host, url.port, connect_opts) do
      Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, upgrade_opts)
    end
  end

  defp schemes("ws"), do: {:ok, :http, :ws}
  defp schemes("wss"), do: {:ok, :https, :wss}
  defp schemes(scheme), do: {:error, {:invalid_scheme, scheme}}

  defp send_close(%State{close_frame: nil} = state, frame) do
    with {:ok, state} <- stream_frame(state, frame) do
      close_timer = internal_event(:close_timeout, state.close_timeout)
      {:ok, %{state | close_timer: close_timer, close_frame: normalize_close(frame)}}
    end
  end

  # only one close handshake at a time
  defp send_close(state, _frame), do: {:error, state, :closing}

  # Mint decodes a payload-less close as 1000/"", so report our shorthand the same way
  defp normalize_close(:close), do: {:close, 1000, ""}
  defp normalize_close(frame), do: frame

  defp close(%State{conn: conn} = state) do
    if conn, do: Mint.HTTP.close(conn)
    cancel_timer(state.close_timer)
    %{state | conn: nil, websocket: nil, request_ref: nil, close_timer: nil, close_frame: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
