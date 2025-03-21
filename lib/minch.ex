defmodule Minch do
  @external_resource "README.md"
  @moduledoc File.read!(@external_resource)
             |> String.split("<!-- @moduledoc -->")
             |> List.last()

  @type client :: GenServer.server()
  @type response_map :: %{status: Mint.Types.status(), headers: Mint.Types.headers()}

  @doc """
  Invoked when the client process is started.
  """
  @callback init(init_arg :: term()) :: {:ok, new_state :: term()}

  @doc """
  Invoked to retrieve the connection details.

  See `Minch.Conn.open/3`.
  """
  @callback connect(state :: term()) ::
              url
              | {url, headers}
              | {url, headers, options}
            when url: String.t() | URI.t(), headers: Mint.Types.headers(), options: Keyword.t()

  @doc """
  Invoked to handle all other messages.
  """
  @callback handle_info(msg :: term(), state :: term()) ::
              {:ok, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
              | {:reconnect, new_state}
            when new_state: term()

  @doc """
  Invoked to handle a successful connection.
  """
  @callback handle_connect(response :: response_map(), state :: term()) ::
              {:ok, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
            when new_state: term()

  @doc """
  Invoked to handle a disconnect from the server or a failed connection attempt.

  Returning `{:reconnect, backoff, state}` will schedule a reconnect after `backoff` milliseconds.

  Returning `{:ok, state}` will keep the client in the disconnected state. Later you can instruct
  the client to reconnect by sending it a message and returning `{:reconnect, state}` from the
  `c:handle_info/2` callback.
  """
  @callback handle_disconnect(reason :: term(), state :: term()) ::
              {:ok, new_state}
              | {:reconnect, backoff :: pos_integer(), new_state}
            when new_state: term()

  @doc """
  Invoked to handle an incoming WebSocket frame.
  """
  @callback handle_frame(frame :: Mint.WebSocket.frame(), state :: term()) ::
              {:ok, new_state}
              | {:reply, frame :: Mint.WebSocket.frame(), new_state}
            when new_state: term()

  @doc """
  Invoked when the client process is about to exit.
  """
  @callback terminate(reason, state :: term()) :: term()
            when reason: :normal | :shutdown | {:shutdown, term()} | term()

  @optional_callbacks init: 1,
                      handle_info: 2,
                      terminate: 2

  @doc """
  Starts a `Minch` client process linked to the current process.
  """
  @spec start_link(module(), any(), GenServer.options()) :: GenServer.on_start()
  def start_link(module, init_arg, options \\ []) do
    Minch.Client.start_link(module, init_arg, options)
  end

  @doc """
  Connects to a WebSocket server.

  Once connected, the function will return the connection's PID and the request reference.

  Use the `send_frame/2` function to send WebSocket frames to the server.

  Incoming WebSocket frames will be sent to the caller's mailbox as a tuple `{:frame, request_ref, frame}`.
  You can use the `receive_frame/2` function to receive these frames.

  Use `Process.monitor/1` to get notified when the connection is closed by the server.

  ## Example

      iex> {:ok, pid, ref} = Minch.connect("wss://ws.postman-echo.com/raw", [], transport_opts: [{:verify, :verify_none}])
      {:ok, _pid, _ref}
      iex> Minch.send_frame(pid, {:text, "hello"})
      :ok
      iex> Minch.receive_frame(ref, 5000)
      {:text, "hello"}
      iex> Minch.close(pid)
      :ok
  """
  @spec connect(String.t() | URI.t(), Mint.Types.headers(), Keyword.t()) ::
          {:ok, pid(), Mint.Types.request_ref()} | {:error, Mint.WebSocket.error()}
  def connect(url, headers \\ [], options \\ []) do
    Minch.SimpleClient.start(url, headers, options)
  end

  @doc """
  Closes the connection opened by `connect/3`.
  """
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Sends a WebSocket frame.
  """
  @spec send_frame(client(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          :ok | {:error, Mint.WebSocket.error() | :not_connected}
  def send_frame(client, frame) do
    Minch.Client.send_frame(client, frame)
  end

  @doc """
  Receives an incoming WebSocket frame.

  See `connect/2`.
  """
  @spec receive_frame(Mint.Types.request_ref(), timeout()) :: Mint.WebSocket.frame() | :timeout
  def receive_frame(ref, timeout \\ 5_000) do
    receive do
      {:frame, ^ref, frame} -> frame
    after
      timeout -> :timeout
    end
  end

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour Minch

      def child_spec(start_opts) do
        Supervisor.child_spec(
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [start_opts]}
          },
          unquote(Macro.escape(opts))
        )
      end

      def init(_init_arg) do
        {:ok, nil}
      end

      def terminate(_reason, _state) do
        :ok
      end

      def handle_info(_message, state) do
        {:ok, state}
      end

      defoverridable child_spec: 1,
                     init: 1,
                     handle_info: 2,
                     terminate: 2
    end
  end
end
