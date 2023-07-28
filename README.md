# Minch

A WebSocket client build around [`Mint.WebSocket`](https://github.com/elixir-mint/mint_web_socket).

## Installation

The package can be installed by adding `minch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:minch, "~> 0.1.0"}
  ]
end
```

<!-- @moduledoc -->

## Usage

### Supervised client

```elixir
defmodule EchoClient do
  use MintSocket

  require Logger

  @impl true
  def init(_init_arg) do
    {:ok, %{connected?: false}}
  end

  @impl true
  def connect(_state) do
    url = "wss://ws.postman-echo.com/raw"
    headers = [{"authorization", "bearer: example"}]
    # don't do this in production
    options = [transport_opts: [{:verify, :verify_none}]]
    {url, headers, options}
  end

  @impl true
  def handle_connect(state) do
    Logger.info("connected")
    Process.send_after(self(), :produce, 5000)
    {:reply, {:text, "welcome"}, %{state | connected?: true}}
  end

  @impl true
  def handle_disconnect(reason, state) do
    Logger.warning("disconnected: #{inspect(reason)}")
    {:reconnect, 1000, %{state | connected?: false}}
  end

  @impl true
  def handle_info(:produce, state) do
    Process.send_after(self(), :produce, 5000)
    {:reply, {:text, DateTime.utc_now() |> DateTime.to_iso8601()}, state}
  end

  @impl true
  def handle_frame(frame, state) do
    Logger.info(inspect(frame))
    {:ok, state}
  end
end
```

### Simple client

```elixir
url = "wss://ws.postman-echo.com/raw"
headers = []
# don't do this in production
options = [transport_opts: [{:verify, :verify_none}]]

IO.puts("checking ping to #{url}...")

case Minch.connect(url, headers, options) do
  {:ok, pid, ref} ->
    Minch.send_frame(pid, {:text, to_string(System.monotonic_time())})

    case Minch.await_frame(ref) do
      {:text, start} ->
        ping =
          System.convert_time_unit(
            System.monotonic_time() - String.to_integer(start),
            :native,
            :millisecond
          )

        IO.puts("#{ping}ms")

      :timeout ->
        IO.puts("timeout")
    end

    Minch.close(pid)

  {:error, error} ->
    IO.puts("connection error: #{inspect(error)}")
end
```
