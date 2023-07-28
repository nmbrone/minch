if Code.ensure_loaded?(:cowboy) do
  defmodule Minch.TestServer do
    @moduledoc false

    defmacro __using__(_) do
      quote do
        @behaviour :cowboy_websocket

        def child_spec(opts) when is_list(opts) do
          {state, transport_opts} = Keyword.pop(opts, :state)

          so_reuse_port =
            case :os.type() do
              {:unix, :linux} -> [{:raw, 0x1, 0xF, <<1::32-native>>}]
              {:unix, :darwin} -> [{:raw, 0xFFFF, 0x0200, <<1::32-native>>}]
              _ -> []
            end

          transport_opts = transport_opts ++ so_reuse_port

          ref = make_ref()

          proto_opts = %{
            env: %{dispatch: :cowboy_router.compile([{:_, [{:_, __MODULE__, state}]}])}
          }

          case :ranch.child_spec(ref, :ranch_tcp, transport_opts, :cowboy_clear, proto_opts) do
            {id, start, restart, shutdown, type, modules} ->
              %{
                id: id,
                start: start,
                restart: restart,
                shutdown: shutdown,
                type: type,
                modules: modules
              }

            child_spec when is_map(child_spec) ->
              child_spec
          end
        end

        @impl true
        def init(req, state) do
          {:cowboy_websocket, req, state}
        end

        defoverridable init: 2
      end
    end
  end
end
