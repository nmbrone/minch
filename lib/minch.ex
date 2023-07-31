defmodule Minch do
  @external_resource "README.md"
  @moduledoc """
  A WebSocket client build around `Mint.WebSocket`.
  """
  @moduledoc @moduledoc <>
               (File.read!(@external_resource)
                |> String.split("<!-- @moduledoc -->")
                |> List.last())

  @type client :: GenServer.server()

  @callback init(init_arg :: term()) :: {:ok, state :: term()}

  @callback connect(state :: term()) ::
              url
              | {url, headers}
              | {url, headers, options}
            when url: String.t() | URI.t(), headers: Mint.Types.headers(), options: Keyword.t()

  @callback handle_info(msg :: :timeout | term(), state :: term()) ::
              {:noreply, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
              | {:reconnect, new_state}
            when new_state: term()

  @callback handle_connect(state :: term()) ::
              {:ok, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
            when new_state: term()

  @callback handle_disconnect(reason :: term(), state :: term()) ::
              {:ok, new_state}
              | {:reconnect, backoff :: pos_integer(), new_state}
            when new_state: term()

  @callback handle_frame(frame :: Mint.WebSocket.frame(), state :: term()) ::
              {:ok, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
            when new_state: term()

  @callback terminate(reason, state :: term()) :: term()
            when reason: :normal | :shutdown | {:shutdown, term()} | term()

  @optional_callbacks connect: 1

  defdelegate start_link(module, init_arg, options \\ []), to: Minch.Client

  defdelegate connect(url, headers \\ [], options \\ []), to: Minch.SimpleClient

  @spec close(client()) :: :ok
  def close(client) do
    GenServer.stop(client)
  end

  @spec send_frame(client(), Mint.WebSocket.frame()) :: :ok | {:error, Mint.WebSocket.error()}
  def send_frame(client, frame) do
    GenServer.call(client, {:send_frame, frame})
  end

  @spec await_frame(Mint.Types.request_ref(), timeout()) :: Mint.WebSocket.frame() | :timeout
  def await_frame(ref, timeout \\ 5_000) do
    receive do
      {:frame, ^ref, frame} -> frame
    after
      timeout -> :timeout
    end
  end

  defmacro __using__(_) do
    quote do
      @behaviour Minch

      def child_spec(init_arg) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg]},
          restart: :transient
        }
      end

      def init(init_arg) do
        {:connect, init_arg}
      end

      def terminate(_reason, _state) do
        :ok
      end

      def handle_info(_message, state) do
        {:noreply, state}
      end

      defoverridable child_spec: 1,
                     init: 1,
                     terminate: 2,
                     handle_info: 2
    end
  end
end
