defmodule Minch.SimpleClient do
  @moduledoc false

  alias Minch.Conn

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
  def terminate(_reason, %{conn: conn}) do
    if not is_nil(conn), do: Conn.close(conn)
    :ok
  end

  @impl true
  def handle_call({:send_frame, frame}, _from, state) do
    case Conn.send_frame(state.conn, frame) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn}}

      {:error, conn, error} ->
        {:reply, {:error, error}, %{state | conn: conn}}
    end
  end

  def handle_call({:connect, url, headers, options}, from, state) do
    case Conn.open(url, headers, options) do
      {:ok, conn} ->
        {:noreply, %{state | conn: conn, caller: from}}

      {:error, error} ->
        GenServer.reply(from, {:error, error})
        {:stop, {:shutdown, error}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason} = message, %{receiver: pid} = state) do
    {:stop, {:shutdown, message}, state}
  end

  def handle_info(message, state) do
    case Conn.stream(state.conn, message) do
      {:ok, conn, response} ->
        {:noreply, %{state | conn: conn} |> handle_connect(response) |> handle_frames(response)}

      {:error, conn, error} ->
        {:stop, {:shutdown, error}, handle_disconnect(%{state | conn: conn}, error)}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_connect(state, %{status: _}) do
    GenServer.reply(state.caller, {:ok, state.conn.request_ref})
    %{state | caller: nil}
  end

  defp handle_connect(state, _response), do: state

  defp handle_disconnect(%{caller: caller} = state, error) when caller != nil do
    GenServer.reply(caller, {:error, error})
    %{state | caller: nil}
  end

  defp handle_disconnect(state, _error), do: state

  defp handle_frames(state, %{frames: frames}) do
    handle_frames(state, frames)
  end

  defp handle_frames(state, [frame | rest]) do
    frame
    |> handle_frame(state)
    |> handle_frames(rest)
  end

  defp handle_frames(state, _), do: state

  defp handle_frame(frame, state) do
    send(state.receiver, {:frame, state.conn.request_ref, frame})
    state
  end
end
