defmodule Minch.Conn do
  @moduledoc false
  @behaviour :gen_statem

  # State transitions:
  # :closed  -> :opening  -- after connecting to the server
  # :opening -> :open     -- after successlul upgrade
  # :opening -> :closed   -- after failed upgrade
  # :open    -> :closing  -- after sending or receiving :close frame
  # :closing -> :closed   -- after server or client closes the connection

  defmodule Data do
    @moduledoc false
    defstruct [
      :conn,
      :conn_attempt,
      :websocket,
      :request_ref,
      :response_status,
      :callback,
      :callback_state,
      :graceful_period
    ]
  end

  @spec start_link(module(), term(), [:gen_statem.start_opt()]) :: :gen_statem.start_ret()
  def start_link(module, init_arg, opts \\ []) do
    apply(:gen_statem, :start_link, start_args(module, init_arg, opts))
  end

  @spec start_link(module(), term(), [:gen_statem.start_opt()]) :: :gen_statem.start_ret()
  def start(module, init_arg, opts \\ []) do
    apply(:gen_statem, :start, start_args(module, init_arg, opts))
  end

  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(conn) do
    :gen_statem.stop(conn)
  end

  defp start_args(module, init_arg, opts) do
    {name, opts} = Keyword.pop(opts, :name)
    args = [__MODULE__, {module, init_arg}, opts]

    case name do
      nil -> args
      name when is_atom(name) -> [{:local, name} | args]
      name -> [name | args]
    end
  end

  @impl true
  def callback_mode(), do: :handle_event_function

  @impl true
  def init({callback, init_arg}) do
    case callback.init(init_arg) do
      {:ok, state} ->
        Process.flag(:trap_exit, true)
        data = %Data{callback: callback, callback_state: state, conn_attempt: 0}
        {:ok, :closed, data, {:next_event, :internal, :connect}}

      {:error, _reason} = error ->
        error

      {:stop, _reson} = stop ->
        stop

      :ignore ->
        :ignore
    end
  end

  @impl true
  def terminate(reason, state, %Data{} = data) do
    if state == :open do
      send_frame(data, :close)
      Mint.HTTP.close(data.conn)
    end

    data.callback.terminate(reason, data.callback_state)
  end

  @impl true
  def handle_event(:info, message, _, data) do
    handle_info(message, data)
  end

  def handle_event(:internal, {:handle_response, message}, state, data) do
    handle_response(message, state, data)
  end

  def handle_event(:internal, {:handle_frame, frame}, :open, data) do
    handle_frame(frame, data)
  end

  def handle_event({:call, from}, {:send_frame, frame}, :open, data) do
    case send_frame(data, frame) do
      {:ok, data} ->
        {:keep_state, data, {:reply, from, :ok}}

      {:error, data, error} ->
        {:keep_state, data, {:reply, from, {:error, error}}}
    end
  end

  def handle_event({:call, from}, {:send_frame, _frame}, _, data) do
    {:keep_state, data, {:reply, from, {:error, :not_connected}}}
  end

  def handle_event(:internal, :connect, :closed, %Data{} = data) do
    {url, headers, options} =
      case data.callback.connect(data.callback_state) do
        {url, headers, options} -> {url, headers, options}
        {url, headers} -> {url, headers, []}
        url -> {url, [], []}
      end

    case connect(url, headers, options) do
      {:ok, conn, ref} ->
        {:next_state, :opening, %{data | conn: conn, conn_attempt: 1, request_ref: ref}}

      {:error, error} ->
        handle_disconnect(error, %{data | conn_attempt: data.conn_attempt + 1})

      {:error, conn, error} ->
        handle_disconnect(error, %{data | conn_attempt: data.conn_attempt + 1, conn: conn})
    end
  end

  def handle_event(:internal, {:send_frame, frame}, :open, data) do
    case send_frame(data, frame) do
      {:ok, data} -> {:keep_state, data}
      {:error, data, error} -> handle_error({:send_frame, error}, data)
    end
  end

  def handle_event(:internal, {:send_frame, _frame}, _, data) do
    handle_error({:send_frame, :not_connected}, data)
  end

  def handle_event(:internal, {:close, _, _} = frame, :open, data) do
    close(data, frame)
  end

  def handle_event(:internal, {:stop, reason}, _, _data) do
    {:stop, reason}
  end

  def handle_event(:state_timeout, :reconnect, :closed, data) do
    {:keep_state, data, {:next_event, :internal, :connect}}
  end

  def handle_event(:state_timeout, {:close, _, _} = frame, :closing, data) do
    handle_disconnect(frame, data)
  end

  defp handle_info(message, %Data{} = data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        actions = Enum.map(responses, &{:next_event, :internal, {:handle_response, &1}})
        {:keep_state, %{data | conn: conn}, actions}

      {:error, conn, error, _responses} ->
        handle_disconnect(error, %{data | conn: conn})

      :unknown ->
        {data, actions} = callback(data, :handle_info, [message, data.callback_state])
        {:keep_state, data, actions}
    end
  end

  defp handle_response({:data, ref, bin}, :open, %Data{request_ref: ref} = data) do
    case Mint.WebSocket.decode(data.websocket, bin) do
      {:ok, websocket, frames} ->
        actions = Enum.map(frames, &{:next_event, :internal, {:handle_frame, &1}})
        {:keep_state, %{data | websocket: websocket}, actions}

      {:error, websocket, error} ->
        handle_error({:decode_frame, error}, %{data | websocket: websocket})
    end
  end

  defp handle_response({:data, ref, _}, _state, %Data{request_ref: ref}) do
    :keep_state_and_data
  end

  defp handle_response({:status, ref, status}, :opening, %Data{request_ref: ref} = data) do
    {:keep_state, %{data | response_status: status}}
  end

  defp handle_response({:headers, ref, headers}, :opening, %Data{request_ref: ref} = data) do
    case Mint.WebSocket.new(data.conn, ref, data.response_status, headers) do
      {:ok, conn, websocket} ->
        data = %{data | conn: conn, websocket: websocket}
        response = %{status: data.response_status, headers: headers}
        {data, actions} = callback(data, :handle_connect, [response, data.callback_state])
        {:next_state, :open, data, actions}

      {:error, conn, error} ->
        handle_disconnect(error, %{data | conn: conn})
    end
  end

  defp handle_response({:error, ref, error}, _state, %Data{request_ref: ref} = data) do
    handle_error({:response, error}, data)
  end

  defp handle_response({:done, ref}, _state, %Data{request_ref: ref}) do
    :keep_state_and_data
  end

  defp handle_frame({:close, _, _} = frame, %Data{} = data) do
    close(data, frame)
  end

  defp handle_frame({:ping, bin}, data) do
    {:keep_state, data, {:next_event, :internal, {:send_frame, {:pong, bin}}}}
  end

  defp handle_frame(frame, %Data{} = data) do
    {data, actions} = callback(data, :handle_frame, [frame, data.callback_state])
    {:keep_state, data, actions}
  end

  defp handle_error(error, %Data{} = data) do
    {data, actions} = callback(data, :handle_error, [error, data.callback_state])
    {:keep_state, data, actions}
  end

  defp handle_disconnect(error, %Data{conn: conn} = data) do
    if conn, do: Mint.HTTP.close(conn)
    data = %{data | conn: conn, websocket: nil, request_ref: nil}

    case data.callback.handle_disconnect(error, data.conn_attempt, data.callback_state) do
      {:reconnect, backoff, state} ->
        actions = {:state_timeout, backoff, :reconnect}
        {:next_state, :closed, %{data | callback_state: state}, actions}

      {:stop, reason, state} ->
        {:stop, reason, %{data | callback_state: state}}
    end
  end

  defp callback(%Data{} = data, name, args) do
    case apply(data.callback, name, args) do
      {:ok, state} ->
        {%{data | callback_state: state}, []}

      {:reply, frames, state} ->
        actions = frames |> List.wrap() |> Enum.map(&{:next_event, :internal, {:send_frame, &1}})
        {%{data | callback_state: state}, actions}

      {:close, code, reason, state} ->
        {%{data | callback_state: state}, {:next_event, :internal, {:close, code, reason}}}

      {:stop, reason, state} ->
        {%{data | callback_state: state}, {:next_event, :internal, {:stop, reason}}}
    end
  end

  defp send_frame(%Data{} = data, frame) do
    case Mint.WebSocket.encode(data.websocket, frame) do
      {:ok, websocket, bin} ->
        case Mint.WebSocket.stream_request_body(data.conn, data.request_ref, bin) do
          {:ok, conn} ->
            {:ok, %{data | conn: conn, websocket: websocket}}

          {:error, conn, error} ->
            {:error, %{data | conn: conn, websocket: websocket}, error}
        end

      {:error, websocket, error} ->
        {:error, %{data | websocket: websocket}, error}
    end
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

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, url.host, url.port, connect_opts) do
      Mint.WebSocket.upgrade(ws_scheme, conn, path, headers, upgrade_opts)
    end
  end

  defp close(data, frame) do
    send_frame(data, frame)
    {:next_state, :closing, data, {:state_timeout, 5000, frame}}
  end
end
