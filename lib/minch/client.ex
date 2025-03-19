defmodule Minch.Client do
  @moduledoc false

  alias Minch.Conn

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:conn, :callback, :callback_state, :timer_ref]
  end

  use GenServer

  @prefix :"$minch"

  @spec start_link(module(), any(), GenServer.options()) :: GenServer.on_start()
  def start_link(module, init_arg, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, init_arg}, opts)
  end

  @impl true
  def init({callback, init_arg}) when is_atom(callback) do
    Process.flag(:trap_exit, true)
    {:ok, callback_state} = callback.init(init_arg)
    {:ok, %State{callback: callback, callback_state: callback_state}, {:continue, :connect}}
  end

  @impl true
  def terminate(reason, %{conn: conn} = state) do
    if not is_nil(conn), do: Conn.close(conn)
    state.callback.terminate(reason, state.callback_state)
    :ok
  end

  @impl true
  def handle_call({:send_frame, frame}, _from, state) do
    case send_frame(state, frame) do
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
        {:noreply, %{state | conn: conn}}

      {:error, error} ->
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
        state = callback_handle_frames(response, state)
        {:noreply, state}

      {:error, conn, error} ->
        Conn.close(conn)
        {:noreply, callback_handle_disconnect(error, %{state | conn: nil})}

      :unknown ->
        {:noreply, callback_handle_info(message, state)}
    end
  end

  defp callback_handle_connect(%{status: _} = response, state) do
    response
    |> state.callback.handle_connect(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_connect(_response, state), do: state

  defp callback_handle_frames(%{frames: frames}, state) do
    Enum.reduce(frames, state, &callback_handle_frame/2)
  end

  defp callback_handle_frames(_response, state), do: state

  defp callback_handle_frame(frame, state) do
    frame
    |> state.callback.handle_frame(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_info(message, state) do
    message
    |> state.callback.handle_info(state.callback_state)
    |> handle_callback_result(state)
  end

  defp callback_handle_disconnect(error, state) do
    error
    |> state.callback.handle_disconnect(state.callback_state)
    |> handle_callback_result(state)
  end

  defp handle_callback_result({:ok, callback_state}, state) do
    %{state | callback_state: callback_state}
  end

  defp handle_callback_result({:reply, frame, callback_state}, state) do
    %{state | callback_state: callback_state} |> send_reply(frame)
  end

  defp handle_callback_result({:reconnect, callback_state}, state) do
    send(self(), {@prefix, :reconnect})
    %{state | callback_state: callback_state}
  end

  defp handle_callback_result({:reconnect, timeout, callback_state}, state) do
    timer_ref = Process.send_after(self(), {@prefix, :reconnect}, timeout)
    %{state | callback_state: callback_state, timer_ref: timer_ref}
  end

  defp send_frame(%{conn: nil} = state, _frame) do
    {:error, state, %Mint.TransportError{reason: :closed}}
  end

  defp send_frame(state, frame) do
    case Conn.send_frame(state.conn, frame) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, error} -> {:error, %{state | conn: conn}, error}
    end
  end

  defp send_reply(state, frame) do
    case send_frame(state, frame) do
      {:ok, state} ->
        state

      {:error, state, error} ->
        Logger.error("Minch failed to send the frame due to the error #{inspect(error)}")
        state
    end
  end
end
