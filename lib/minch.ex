defmodule Minch do
  @external_resource "README.md"
  @moduledoc File.read!(@external_resource)
             |> String.split("<!-- @moduledoc -->")
             |> List.last()

  @type client :: :gen_statem.server_ref()
  @type state :: term()
  @type response :: %{status: Mint.Types.status(), headers: Mint.Types.headers()}
  @type frame :: Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()

  @type callback_result ::
          {:ok, state()}
          | {:reply, frame() | [frame()], state()}
          | {:stop, reason :: term()}

  @doc """
  Invoked when the client process is started.
  """
  @callback init(init_arg :: term()) :: {:ok, state()}

  @doc """
  Invoked to retrieve the connection details.

  See options for `Mint.HTTP.connect/4` and `Mint.WebSocket.upgrade/5`.
  """
  @callback connect(state :: state()) ::
              url
              | {url, headers}
              | {url, headers, options}
            when url: String.t() | URI.t(), headers: Mint.Types.headers(), options: Keyword.t()

  @doc """
  Invoked to handle info messages.
  """
  @callback handle_info(message :: term(), state()) :: callback_result()

  @doc """
  Invoked to handle a successful connection.
  """
  @callback handle_connect(response(), state()) :: callback_result()

  @doc """
  Invoked to handle a disconnect from the server or a failed connection attempt.

  Returning `{:reconnect, backoff, state}` will schedule a reconnect after `backoff` milliseconds.
  """
  @callback handle_disconnect(reason :: term(), attempt :: pos_integer(), state()) ::
              {:reconnect, backoff :: pos_integer(), state()}
              | {:stop, reason :: term()}

  @doc """
  Invoked to handle internal errors.
  """
  @callback handle_error(error :: term(), state()) :: callback_result()

  @doc """
  Invoked to handle an incoming WebSocket frame.
  """
  @callback handle_frame(Mint.WebSocket.frame(), state()) :: callback_result()

  @doc """
  Invoked when the client process is about to exit.
  """
  @callback terminate(reason, state :: state()) :: term()
            when reason: :normal | :shutdown | {:shutdown, term()} | term()

  @doc """
  Starts a `Minch` client process linked to the current process.
  """
  @spec start_link(module(), term(), [:gen_statem.start_opt()]) :: :gen_statem.start_ret()
  def start_link(module, init_arg, opts \\ []) do
    Minch.Conn.start_link(module, init_arg, opts)
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
    Minch.Conn.stop(pid)
  end

  @doc """
  Sends a WebSocket frame.
  """
  @spec send_frame(client(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          :ok | {:error, term()}
  def send_frame(client, frame) do
    :gen_statem.call(client, {:send_frame, frame})
  end

  @doc """
  Receives an incoming WebSocket frame.

  See `connect/3`.
  """
  @spec receive_frame(Mint.Types.request_ref(), timeout()) :: Mint.WebSocket.frame() | :timeout
  def receive_frame(ref, timeout \\ 5_000) do
    receive do
      {:frame, ^ref, frame} -> frame
    after
      timeout -> :timeout
    end
  end

  @doc """
  Calculates an exponential backoff duration.

  It accepts the following options:

    * `:min` - The minimum backoff duration in milliseconds. Defaults to `200`.
    * `:max` - The maximum backoff duration in milliseconds. Defaults to `30_000`.
    * `:factor` - The exponent to apply to the attempt number. Defaults to `2`.

  ## Examples

      iex(8)> for attempt <- 1..20, do: Minch.backoff(attempt)
      [200, 800, 1800, 3200, 5000, 7200, 9800, 12800, 16200, 20000, 24200, 28800,
      30000, 30000, 30000, 30000, 30000, 30000, 30000, 30000]

      for attempt <- 1..20, do: Minch.backoff(attempt, min: 100, max: 10000, factor: 1.5)
      [100, 283, 520, 800, 1118, 1470, 1852, 2263, 2700, 3162, 3648, 4157, 4687, 5238,
       5809, 6400, 7009, 7637, 8282, 8944]
  """
  @spec backoff(non_neg_integer(),
          min: pos_integer(),
          max: pos_integer(),
          factor: pos_integer()
        ) :: non_neg_integer()
  def backoff(attempt, opts \\ []) do
    min = Keyword.get(opts, :min, 200)
    max = Keyword.get(opts, :max, 30_000)
    factor = Keyword.get(opts, :factor, 2)
    (min * :math.pow(attempt, factor)) |> round() |> min(max)
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

      def init(init_arg) do
        {:ok, init_arg}
      end

      def terminate(_reason, _state) do
        :ok
      end

      def handle_connect(_, state) do
        {:ok, state}
      end

      def handle_disconnect(_reason, attempt, state) do
        {:reconnect, Minch.backoff(attempt), state}
      end

      def handle_info(_message, state) do
        {:ok, state}
      end

      def handle_error(error, state) do
        require Logger
        Logger.error([inspect(__MODULE__), " - ", inspect(error)])
        {:ok, state}
      end

      defoverridable child_spec: 1,
                     init: 1,
                     handle_connect: 2,
                     handle_disconnect: 3,
                     handle_info: 2,
                     handle_error: 2,
                     terminate: 2
    end
  end
end
