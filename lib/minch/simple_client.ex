defmodule Minch.SimpleClient do
  @moduledoc false

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [:receiver, :conn, :caller]
  end

  @spec connect(String.t() | URI.t(), Mint.Types.headers(), Keyword.t()) ::
          {:ok, pid(), Mint.Types.request_ref()} | {:error, Mint.WebSocket.error()}
  def connect(url, headers \\ [], options \\ []) do
    # the default timeout is 30_000
    timeout = (options[:transport_options][:timeout] || 30_000) + 1_000

    with {:ok, pid} <- GenServer.start(__MODULE__, self()),
         {:ok, ref} <- GenServer.call(pid, {:connect, url, headers, options}, timeout) do
      {:ok, pid, ref}
    end
  end

  @impl true
  def init(receiver) when is_pid(receiver) do
    Process.flag(:trap_exit, true)
    Process.monitor(receiver)
    {:ok, %State{receiver: receiver}}
  end

  @impl true
  def terminate(_reason, state) do
    unless is_nil(state.conn), do: Minch.Conn.close(state.conn)
    :ok
  end

  @impl true
  def handle_call({:send_frame, frame}, _from, state) do
    case Minch.Conn.send_frame(state.conn, frame) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn}}

      {:error, conn, error} ->
        {:reply, {:error, error}, %{state | conn: conn}}
    end
  end

  def handle_call({:connect, url, headers, options}, from, state) do
    case Minch.Conn.open(url, headers, options) do
      {:ok, conn} ->
        {:noreply, %{state | conn: conn, caller: from}}

      {:error, error} ->
        GenServer.reply(from, {:error, error})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{receiver: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(message, state) do
    case Minch.Conn.stream(state.conn, message) do
      {:ok, conn, []} ->
        {:noreply, reply(%{state | conn: conn}, {:ok, conn.request_ref})}

      {:ok, conn, frames} ->
        {:noreply, handle_frames(%{state | conn: conn}, frames)}

      {:error, error} ->
        {:stop, :normal, reply(state, {:error, error})}

      :unknown ->
        {:noreply, state}
    end
  end

  defp reply(%{caller: nil} = state, _message), do: state

  defp reply(%{caller: caller} = state, message) do
    GenServer.reply(caller, message)
    %{state | caller: nil}
  end

  defp handle_frames(state, [frame | rest]) do
    frame
    |> handle_frame(state)
    |> handle_frames(rest)
  end

  defp handle_frames(state, []), do: state

  defp handle_frame(frame, state) do
    send(state.receiver, {:frame, state.conn.request_ref, frame})
    state
  end
end
