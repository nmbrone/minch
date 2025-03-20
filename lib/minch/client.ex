defmodule Minch.Client do
  @moduledoc false

  alias Minch.Conn

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:conn, :conn_attempt, :callback, :callback_state, :timer_ref]
  end

  use GenServer

  @prefix :"$minch"

  @spec send_frame(GenServer.server(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          :ok | {:error, Mint.WebSocket.error() | :not_connected}
  def send_frame(client, frame) do
    GenServer.call(client, {@prefix, :send_frame, frame})
  end

  @spec start_link(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start_link(module, init_arg, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, init_arg}, opts)
  end

  @spec start(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start(module, init_arg, opts \\ []) do
    GenServer.start(__MODULE__, {module, init_arg}, opts)
  end

  @impl true
  def init({callback, init_arg}) when is_atom(callback) do
    Process.flag(:trap_exit, true)
    {:ok, callback_state} = callback.init(init_arg)
    state = %State{callback: callback, callback_state: callback_state, conn_attempt: 0}
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def terminate(reason, %{conn: conn} = state) do
    if not is_nil(conn), do: Conn.close(conn)
    state.callback.terminate(reason, state.callback_state)
    :ok
  end

  @impl true
  def handle_call({@prefix, :send_frame, frame}, _from, state) do
    case do_send_frame(state, frame) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, state, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_continue(:connect, %{conn: nil} = state) do
    {url, headers, options} =
      case state.callback.connect(state.callback_state) do
        {url, headers, options} -> {url, headers, options}
        {url, headers} -> {url, headers, []}
        url -> {url, [], []}
      end

    case Conn.open(url, headers, options) do
      {:ok, conn} ->
        {:noreply, %{state | conn: conn, conn_attempt: 0}}

      {:error, error} ->
        state = %{state | conn_attempt: state.conn_attempt + 1}
        {:noreply, callback_handle_disconnect(error, state)}
    end
  end

  def handle_continue(:connect, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({@prefix, :reconnect}, state) do
    if ref = state.timer_ref, do: Process.cancel_timer(ref)
    {:noreply, %{state | timer_ref: nil}, {:continue, :connect}}
  end

  def handle_info(message, %{conn: nil} = state) do
    {:noreply, callback_handle_info(message, state)}
  end

  def handle_info(message, state) do
    case Conn.stream(state.conn, message) do
      {:ok, conn, response} ->
        state = %{state | conn: conn}
        state = callback_handle_connect(response, state)
        state = handle_frames(response, state)
        {:noreply, state}

      {:error, conn, error, _response} ->
        Conn.close(conn)
        {:noreply, callback_handle_disconnect(error, %{state | conn: nil})}

      :unknown ->
        {:noreply, callback_handle_info(message, state)}
    end
  end

  defp handle_frames(%{frames: frames}, state) do
    Enum.reduce(frames, state, &handle_frame/2)
  end

  defp handle_frames(_response, state), do: state

  defp handle_frame({:close, _, _} = frame, state) do
    Conn.close(state.conn)
    callback_handle_disconnect(frame, %{state | conn: nil})
  end

  defp handle_frame({:ping, data}, state) do
    reply(state, {:pong, data})
  end

  defp handle_frame(frame, state) do
    callback_handle_frame(frame, state)
  end

  defp callback_handle_frame(frame, state) do
    frame
    |> state.callback.handle_frame(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_connect(%{status: _} = response, state) do
    response
    |> state.callback.handle_connect(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_connect(_response, state), do: state

  defp callback_handle_info(message, state) do
    message
    |> state.callback.handle_info(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_disconnect(error, state) do
    error
    |> state.callback.handle_disconnect(state.conn_attempt, state.callback_state)
    |> handle_callback_result(state)
  end

  defp handle_callback_result({:ok, callback_state}, state) do
    %{state | callback_state: callback_state}
  end

  defp handle_callback_result({:reply, frame, callback_state}, state) do
    %{state | callback_state: callback_state} |> reply(frame)
  end

  defp handle_callback_result({:reconnect, callback_state}, state) do
    send(self(), {@prefix, :reconnect})
    %{state | callback_state: callback_state}
  end

  defp handle_callback_result({:reconnect, timeout, callback_state}, state) do
    timer_ref = Process.send_after(self(), {@prefix, :reconnect}, timeout)
    %{state | callback_state: callback_state, timer_ref: timer_ref}
  end

  defp do_send_frame(%{conn: nil} = state, _frame) do
    {:error, state, :not_connected}
  end

  defp do_send_frame(state, frame) do
    case Conn.send_frame(state.conn, frame) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, error} -> {:error, %{state | conn: conn}, error}
    end
  end

  defp reply(state, frame) do
    case do_send_frame(state, frame) do
      {:ok, state} ->
        state

      {:error, state, error} ->
        Logger.error("Minch failed to send the frame due to the error #{inspect(error)}")
        state
    end
  end
end
