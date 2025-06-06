defmodule Minch.SimpleClient do
  @moduledoc false
  use Minch

  alias __MODULE__, as: State

  defstruct [:url, :headers, :options, :receiver, :receiver_ref, :monitor_ref, :connected?]

  @spec start(String.t() | URI.t(), Mint.Types.headers(), Keyword.t()) ::
          {:ok, pid(), reference()} | {:error, Mint.WebSocket.error() | :timeout}
  def start(url, headers \\ [], options \\ []) do
    # the default timeout is 30_000
    # https://hexdocs.pm/mint/Mint.HTTP.html#connect/4-transport-options
    timeout = options[:transport_opts][:timeout] || 30_000

    ref = make_ref()

    state = %State{
      url: url,
      headers: headers,
      options: options,
      receiver: self(),
      receiver_ref: ref,
      connected?: false
    }

    with {:ok, pid} <- Minch.Conn.start(__MODULE__, state) do
      receive do
        {:connected, ^ref} -> {:ok, pid, ref}
        {:connection_error, ^ref, reason} -> {:error, reason}
      after
        timeout ->
          Minch.Conn.stop(pid)
          {:error, :timeout}
      end
    end
  end

  @impl true
  def init(%State{} = state) do
    {:ok, %{state | monitor_ref: Process.monitor(state.receiver)}}
  end

  @impl true
  def connect(%State{} = state) do
    {state.url, state.headers, state.options}
  end

  @impl true
  def handle_connect(_response, %State{} = state) do
    send(state.receiver, {:connected, state.receiver_ref})
    {:ok, %{state | connected?: true}}
  end

  @impl true
  def handle_disconnect(reason, _attempt, %State{} = state) do
    if not state.connected? do
      send(state.receiver, {:connection_error, state.receiver_ref, reason})
    end

    {:stop, {:shutdown, reason}, state}
  end

  @impl true
  def handle_frame(frame, %State{} = state) do
    send(state.receiver, {:frame, state.receiver_ref, frame})
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{monitor_ref: ref} = state) do
    {:stop, {:shutdown, :receiver_down}, state}
  end
end
