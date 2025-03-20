defmodule Minch.Conn do
  @moduledoc """
  Minch WebSocket connection.
  """

  defmodule NotUpgradedError do
    @moduledoc """
    An error representing a failure to send a frame via a connection that was not upgraded
    from HTTP to WebSocket.
    """

    @type t :: %__MODULE__{
            message: String.t()
          }

    defstruct message: "connection is not upgraded to WebSocket"
  end

  defmodule UpgradeFailureError do
    @moduledoc """
    An error representing a failure to upgrade protocols from HTTP to WebSocket.

    It is the same as `Mint.WebSocket.UpgradeFailureError` but also contains the response body.
    """
    @type t :: %__MODULE__{
            status: Mint.Types.status(),
            headers: Mint.Types.headers(),
            body: binary() | nil
          }

    defstruct [:status, :headers, :body]
  end

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          request_ref: Mint.Types.request_ref(),
          websocket: Mint.WebSocket.t() | nil
        }

  defstruct [:conn, :request_ref, :websocket]

  @type response :: %{
          optional(:status) => Mint.Types.status(),
          optional(:headers) => Mint.Types.headers(),
          optional(:data) => binary(),
          optional(:error) => term(),
          optional(:frames) => [Mint.WebSocket.frame()]
        }

  @doc """
  Opens a new connection.

  For the available options see `Mint.HTTP.connect/4` and `Mint.WebSocket.upgrade/5` functions.
  """
  @spec open(String.t() | URI.t(), Mint.Types.headers(), Keyword.t()) ::
          {:ok, t()} | {:error, Mint.WebSocket.error()}
  def open(url, headers \\ [], options \\ []) do
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
      {:ok, %__MODULE__{conn: conn, request_ref: ref}}
    else
      {:error, error} ->
        {:error, error}

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, error}
    end
  end

  @doc """
  Sends the `:close` frame and closes the connection.

  See `Mint.HTTP.close/1`.
  """
  @spec close(t()) :: t()
  def close(state) do
    state =
      case send_frame(state, :close) do
        {:ok, state} -> state
        {:error, state, _reason} -> state
      end

    {:ok, conn} = Mint.HTTP.close(state.conn)
    %{state | conn: conn}
  end

  @doc """
  Checks whether the connection is open.

  See `Mint.HTTP.open?/2`.
  """
  @spec open?(t(), :read | :write) :: boolean()
  def open?(state, type \\ :write) do
    Mint.HTTP.open?(state.conn, type)
  end

  @doc """
  Send a frame via the connection.
  """
  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          {:ok, t()} | {:error, t(), NotUpgradedError.t() | Mint.Types.error() | term()}
  def send_frame(state, frame)

  def send_frame(%{websocket: nil} = state, _) do
    {:error, state, %NotUpgradedError{}}
  end

  def send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, error} ->
            {:error, %{state | conn: conn, websocket: websocket}, error}
        end

      {:error, websocket, error} ->
        {:error, %{state | websocket: websocket}, error}
    end
  end

  @doc """
  Wraps `Mint.WebSocket.stream/2` and decodes WebSocket frames.
  """
  @spec stream(t(), term()) ::
          {:ok, t(), response()} | {:error, t(), error, response()} | :unknown
        when error: Mint.Types.error() | Mint.WebSocketError.t() | UpgradeFailureError.t()
  def stream(state, http_reply) do
    case Mint.WebSocket.stream(state.conn, http_reply) do
      {:ok, conn, responses} ->
        responses
        |> build_response(state.request_ref)
        |> handle_response(%{state | conn: conn})

      {:error, conn, error, responses} ->
        {:error, %{state | conn: conn}, error, build_response(responses, state.request_ref)}

      :unknown ->
        :unknown
    end
  end

  defp build_response(responses, ref, response \\ %{})

  defp build_response([{key, ref, val} | rest], ref, response) do
    build_response(rest, ref, Map.put(response, key, val))
  end

  defp build_response([{:done, ref}], ref, response), do: response
  defp build_response([], _ref, response), do: response

  # upgrade response
  defp handle_response(%{status: status, headers: headers} = response, state) do
    case Mint.WebSocket.new(state.conn, state.request_ref, status, headers) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}

        case response do
          %{data: _} -> handle_response(response, state)
          _no_frames -> {:ok, state, response}
        end

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{}} ->
        {:error, %{state | conn: conn},
         %UpgradeFailureError{status: status, headers: headers, body: response[:data]}}

      {:error, conn, error} ->
        {:error, %{state | conn: conn}, error}
    end
  end

  # WebSocket frames
  defp handle_response(response, state) do
    case Mint.WebSocket.decode(state.websocket, response.data) do
      {:ok, websocket, frames} ->
        {:ok, %{state | websocket: websocket}, Map.put(response, :frames, frames)}

      {:error, websocket, error} ->
        {:error, %{state | websocket: websocket}, error}
    end
  end
end
