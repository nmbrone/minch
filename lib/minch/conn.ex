defmodule Minch.Conn do
  @type t :: %__MODULE__{
          conn: Mint.HTTP.t(),
          request_ref: Mint.Types.request_ref(),
          status: non_neg_integer() | nil,
          headers: Mint.Types.headers() | nil,
          websocket: Mint.WebSocket.t() | nil
        }

  defstruct [:conn, :request_ref, :websocket, :status, :headers]

  @spec open?(t()) :: boolean()
  def open?(state) do
    Mint.HTTP.open?(state.conn) and not is_nil(state.websocket)
  end

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

  @spec close(t()) :: t()
  def close(c) do
    if open?(c) do
      send_frame(c, :close)
      {:ok, conn} = Mint.HTTP.close(c.conn)
      %{c | conn: conn}
    else
      c
    end
  end

  @spec send_frame(t(), Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame()) ::
          {:ok, t()} | {:error, t(), term()}
  def send_frame(c, frame) when c.websocket != nil do
    case Mint.WebSocket.encode(c.websocket, frame) do
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

  @spec stream(t(), term()) ::
          {:ok, t(), [Mint.WebSocket.frame()]} | {:error, Mint.WebSocket.error()} | :unknown
  def stream(c, http_reply) do
    case Mint.WebSocket.stream(c.conn, http_reply) do
      {:ok, conn, responses} ->
        handle_responses(%{c | conn: conn}, responses)

      {:error, conn, error, _responses} ->
        Mint.HTTP.close(conn)
        {:error, error}

      :unknown ->
        :unknown
    end
  end

  # upgrade response
  defp handle_responses(%{conn: conn, request_ref: ref, websocket: nil} = c, responses) do
    resp =
      Enum.reduce(responses, %{status: nil, headers: nil, data: nil}, fn
        {:status, ^ref, status}, resp -> %{resp | status: status}
        {:headers, ^ref, headers}, resp -> %{resp | headers: headers}
        {:data, ^ref, data}, resp -> %{resp | data: data}
        {:done, ^ref}, resp -> resp
      end)

    case Mint.WebSocket.new(conn, ref, resp.status, resp.headers) do
      {:ok, conn, websocket} ->
        {:ok, %{c | conn: conn, websocket: websocket}, []}

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        {:error, error}
    end
  end

  # websocket frames
  defp handle_responses(%{request_ref: ref} = c, [{:data, ref, data}]) do
    case Mint.WebSocket.decode(c.websocket, data) do
      {:ok, websocket, frames} ->
        {:ok, %{c | websocket: websocket}, frames}

      {:error, _websocket, error} ->
        Mint.HTTP.close(c.conn)
        {:error, error}
    end
  end
end
