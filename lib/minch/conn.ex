defmodule Minch.Conn do
  @moduledoc """
  Minch WebSocket connection.
  """

  defmodule NotUpgradedError do
    @type t :: %__MODULE__{
            message: String.t()
          }

    defstruct message: "connection is not upgraded to WebSocket"
  end

  defmodule UpgradeFailureError do
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
  Gracefully closes the connection if it's still open.
  """
  @spec close(t()) :: t()
  def close(%{conn: conn} = c) do
    if Mint.HTTP.open?(conn) do
      send_frame(c, :close)
      {:ok, conn} = Mint.HTTP.close(conn)
      %{c | conn: conn}
    else
      c
    end
  end

  @doc """
  Wraps `Mint.HTTP.open?/2`.
  """
  def open?(c, type \\ :read_write) do
    Mint.HTTP.open?(c.conn, type)
  end

  @doc """
  Send a frame via the connection.
  """
  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          {:ok, t()} | {:error, t(), NotUpgradedError.t() | Mint.Types.error() | term()}
  def send_frame(%{websocket: websocket} = c, frame) when websocket != nil do
    case Mint.WebSocket.encode(websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(c.conn, c.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{c | conn: conn, websocket: websocket}}

          {:error, conn, error} ->
            {:error, %{c | conn: conn, websocket: websocket}, error}
        end

      {:error, websocket, error} ->
        {:error, %{c | websocket: websocket}, error}
    end
  end

  def send_frame(c, _) do
    {:error, c, %NotUpgradedError{}}
  end

  @doc """
  Wraps `Mint.WebSocket.stream/2` and decodes WebSocket frames.
  """
  @spec stream(t(), term()) ::
          {:ok, t(), response()}
          | {:error, t(), Mint.Types.error() | Mint.WebSocketError.t() | UpgradeFailureError.t()}
          | :unknown
  def stream(c, http_reply) do
    case Mint.WebSocket.stream(c.conn, http_reply) do
      {:ok, conn, responses} ->
        responses
        |> build_response(c.request_ref)
        |> handle_response(%{c | conn: conn})

      {:error, conn, error, _responses} ->
        {:error, %{c | conn: conn}, error}

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

  # WebSocket frames
  defp handle_response(%{data: data} = response, %{websocket: websocket} = c)
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        {:ok, %{c | websocket: websocket}, Map.put(response, :frames, frames)}

      {:error, websocket, error} ->
        {:error, %{c | websocket: websocket}, error}
    end
  end

  # upgrade response
  defp handle_response(%{status: status, headers: headers} = response, c) do
    case Mint.WebSocket.new(c.conn, c.request_ref, status, headers) do
      {:ok, conn, websocket} ->
        c = %{c | conn: conn, websocket: websocket}

        case response do
          %{data: _} -> handle_response(response, c)
          _no_frames -> {:ok, c, response}
        end

      {:error, conn, %Mint.WebSocket.UpgradeFailureError{}} ->
        {:error, %{c | conn: conn},
         %UpgradeFailureError{status: status, headers: headers, body: response[:data]}}

      {:error, conn, error} ->
        {:error, %{c | conn: conn}, error}
    end
  end
end
