defmodule Minch.Client do
  @moduledoc false

  alias Minch.Conn

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:conn, :callback, :callback_state, :timer]
  end

  use GenServer

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
        {:noreply, handle_disconnect(state, error)}
    end
  end

  def handle_continue(:connect, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:"$minch", :reconnect}, state) do
    {:noreply, %{state | timer: nil}, {:continue, :connect}}
  end

  def handle_info(message, %{conn: nil} = state) do
    do_handle_info(message, state)
  end

  def handle_info(message, state) do
    case Conn.stream(state.conn, message) do
      {:ok, conn, %{frames: frames}} ->
        {:noreply, Enum.reduce(frames, %{state | conn: conn}, &handle_frame/2)}

      {:ok, conn, response} ->
        {:noreply, handle_connect(response, %{state | conn: conn})}

      {:error, conn, error} ->
        Conn.close(conn)
        {:noreply, handle_disconnect(%{state | conn: nil}, error)}

      :unknown ->
        do_handle_info(message, state)
    end
  end

  defp handle_frame(frame, state) do
    case state.callback.handle_frame(frame, state.callback_state) do
      {:ok, callback_state} ->
        %{state | callback_state: callback_state}

      {:reply, frame, callback_state} ->
        {:ok, state} = send_reply(state, frame)
        %{state | callback_state: callback_state}
    end
  end

  defp handle_connect(response, state) do
    case state.callback.handle_connect(response, state.callback_state) do
      {:ok, callback_state} ->
        %{state | callback_state: callback_state}

      {:reply, frame, callback_state} ->
        {:ok, state} = send_reply(state, frame)
        %{state | callback_state: callback_state}
    end
  end

  defp handle_disconnect(state, error) do
    case state.callback.handle_disconnect(error, state.callback_state) do
      {:reconnect, backoff, callback_state} ->
        timer = Process.send_after(self(), {:"$minch", :reconnect}, backoff)
        %{state | callback_state: callback_state, timer: timer}

      {:ok, callback_state} ->
        %{state | callback_state: callback_state}
    end
  end

  defp do_handle_info(message, state) do
    case state.callback.handle_info(message, state.callback_state) do
      {:ok, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}}

      {:reply, frame, callback_state} ->
        {:ok, state} = send_reply(state, frame)
        {:noreply, %{state | callback_state: callback_state}}

      {:reconnect, callback_state} ->
        {:noreply, %{state | callback_state: callback_state}, {:continue, :connect}}
    end
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
        {:ok, state}

      {:error, state, error} ->
        Logger.error(inspect(error))
        {:ok, state}
    end
  end
end
