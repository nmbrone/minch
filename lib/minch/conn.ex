defmodule Minch.Conn do
  @moduledoc false
  @behaviour :gen_statem

  defmodule Data do
    @moduledoc false
    defstruct [
      :conn,
      :conn_attempt,
      :websocket,
      :request_ref,
      :response_status,
      :response_headers,
      :callback,
      :callback_state
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
  def callback_mode(), do: :state_functions

  @impl true
  def init({callback, init_arg}) do
    case callback.init(init_arg) do
      {:ok, state} ->
        Process.flag(:trap_exit, true)
        data = %Data{callback: callback, callback_state: state, conn_attempt: 0}
        {:ok, :disconnected, data, {:next_event, :internal, :connect}}

      {:error, _reason} = error ->
        error

      {:stop, _reson} = stop ->
        stop

      :ignore ->
        :ignore
    end
  end

  @impl true
  def terminate(reason, _state, %Data{} = data) do
    if data.websocket, do: send_frame(data, :close)
    if data.conn, do: Mint.HTTP.close(data.conn)
    data.callback.terminate(reason, data.callback_state)
  end

  @doc false
  def disconnected(:info, message, data) do
    handle_info(message, data)
  end

  def disconnected({:call, from}, {:send_frame, _frame}, data) do
    {:keep_state, data, {:reply, from, {:error, :not_connected}}}
  end

  def disconnected(:internal, :connect, %Data{} = data) do
    {url, headers, options} =
      case data.callback.connect(data.callback_state) do
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
      {:keep_state, %{data | conn: conn, conn_attempt: 1, request_ref: ref}}
    else
      {:error, error} ->
        handle_disconnect(error, %{data | conn_attempt: data.conn_attempt + 1})

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        handle_disconnect(error, %{data | conn_attempt: data.conn_attempt + 1})
    end
  end

  def disconnected(:internal, {:status, ref, status}, %Data{request_ref: ref} = data) do
    {:keep_state, %{data | response_status: status}}
  end

  def disconnected(:internal, {:headers, ref, headers}, %Data{request_ref: ref} = data) do
    case Mint.WebSocket.new(data.conn, ref, data.response_status, headers) do
      {:ok, conn, websocket} ->
        data = %{data | conn: conn, websocket: websocket, response_headers: headers}
        response = %{status: data.response_status, headers: headers}
        {data, actions} = callback(data, :handle_connect, [response, data.callback_state])
        {:next_state, :connected, data, actions}

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        handle_disconnect(error, %{data | conn: nil})
    end
  end

  def disconnected(:internal, {:data, ref, _}, %Data{request_ref: ref}) do
    :keep_state_and_data
  end

  def disconnected(:internal, {:error, ref, error}, %Data{request_ref: ref} = data) do
    handle_error({:response, error}, data)
  end

  def disconnected(:internal, {:done, ref}, %Data{request_ref: ref}) do
    :keep_state_and_data
  end

  def disconnected(:internal, {:stop, reason}, _data) do
    {:stop, reason}
  end

  def disconnected(:internal, {:send_frame, _frame}, data) do
    handle_error({:send_frame, :not_connected}, data)
  end

  def disconnected(:state_timeout, :reconnect, data) do
    {:keep_state, data, {:next_event, :internal, :connect}}
  end

  @doc false
  def connected(:info, message, data) do
    handle_info(message, data)
  end

  def connected({:call, from}, {:send_frame, frame}, data) do
    case send_frame(data, frame) do
      {:ok, data} ->
        {:keep_state, data, {:reply, from, :ok}}

      {:error, data, error} ->
        {:keep_state, data, {:reply, from, {:error, error}}}
    end
  end

  def connected(:internal, {:data, ref, bin}, %Data{request_ref: ref} = data) do
    case Mint.WebSocket.decode(data.websocket, bin) do
      {:ok, websocket, frames} ->
        data = %{data | websocket: websocket}
        actions = Enum.map(frames, &{:next_event, :internal, {:frame, &1}})
        {:keep_state, data, actions}

      {:error, websocket, error} ->
        handle_error({:decode_frame, error}, %{data | websocket: websocket})
    end
  end

  def connected(:internal, {:frame, frame}, data) do
    handle_frame(frame, data)
  end

  def connected(:internal, {:error, ref, error}, %Data{request_ref: ref} = data) do
    handle_error({:response, error}, data)
  end

  def connected(:internal, {:done, ref}, %Data{request_ref: ref}) do
    :keep_state_and_data
  end

  def connected(:internal, {:stop, reason}, _data) do
    {:stop, reason}
  end

  def connected(:internal, {:send_frame, frame}, data) do
    case send_frame(data, frame) do
      {:ok, data} -> {:keep_state, data}
      {:error, data, error} -> handle_error({:send_frame, error}, data)
    end
  end

  defp handle_info(message, %Data{} = data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        actions = Enum.map(responses, &{:next_event, :internal, &1})
        {:keep_state, %{data | conn: conn}, actions}

      {:error, conn, error, responses} ->
        handle_error({:stream_response, error, responses}, %{data | conn: conn})

      :unknown ->
        {data, actions} = callback(data, :handle_info, [message, data.callback_state])
        {:keep_state, data, actions}
    end
  end

  defp handle_frame({:close, _, _} = frame, %Data{} = data) do
    Mint.HTTP.close(data.conn)
    handle_disconnect(frame, %{data | conn: nil, websocket: nil})
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

  defp handle_disconnect(error, %Data{} = data) do
    case data.callback.handle_disconnect(error, data.conn_attempt, data.callback_state) do
      {:reconnect, backoff, state} ->
        data = %{data | callback_state: state}
        actions = [{:state_timeout, backoff, :reconnect}]
        {:next_state, :disconnected, data, actions}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  defp callback(%Data{} = data, name, args) do
    case apply(data.callback, name, args) do
      {:ok, state} ->
        {%{data | callback_state: state}, []}

      {:reply, frames, state} ->
        actions = frames |> List.wrap() |> Enum.map(&{:next_event, :internal, {:send_frame, &1}})
        {%{data | callback_state: state}, actions}

      {:stop, reason} ->
        {data, {:next_event, :internal, {:stop, reason}}}
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
end
