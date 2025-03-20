if Code.ensure_loaded?(Bandit) and Code.ensure_loaded?(WebSockAdapter) do
  defmodule Minch.TestServer do
    @moduledoc false

    defmodule UpgradePlug do
      @moduledoc false
      use Plug.Builder, copy_opts_to_assign: :opts

      plug(:connect)
      plug(:upgrade)

      defp connect(%{assigns: %{opts: {handler, state, upgrade_opts}}} = conn, _) do
        {conn, state} = handler.connect(conn, state)
        assign(conn, :opts, {handler, state, upgrade_opts})
      end

      defp upgrade(%{assigns: %{opts: {handler, state, upgrade_opts}}} = conn, _) do
        conn
        |> WebSockAdapter.upgrade(handler, state, upgrade_opts)
        |> Plug.Conn.halt()
      end
    end

    def start_link(handler, state, upgrade_opts \\ [], bandit_opts \\ []) do
      bandit_opts
      |> Keyword.put(:plug, {UpgradePlug, {handler, state, upgrade_opts}})
      |> Keyword.put_new(:startup_log, false)
      |> Bandit.start_link()
    end

    defmacro __using__(_) do
      quote location: :keep do
        @behaviour WebSock

        def child_spec(opts) do
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [opts]}
          }
        end

        def start_link(opts) do
          {state, opts} = Keyword.pop(opts, :state)
          {upgrade_opts, bandit_opts} = Keyword.split(opts, [:upgrade_opts])
          Minch.TestServer.start_link(__MODULE__, state, upgrade_opts, bandit_opts)
        end

        def connect(conn, state) do
          {conn, state}
        end

        defoverridable connect: 2
      end
    end
  end
end
