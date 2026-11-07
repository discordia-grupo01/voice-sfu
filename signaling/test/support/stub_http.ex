defmodule DiscordiaSignaling.StubHTTP do
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if notify = Keyword.get(opts, :notify) do
      send(notify, {:stub_request, conn.method, conn.request_path, conn.req_headers})
    end

    if delay = Keyword.get(opts, :delay_ms), do: Process.sleep(delay)

    send_resp(conn, Keyword.get(opts, :status, 200), Keyword.get(opts, :body, "{}"))
  end

  def start(opts \\ []) do
    ref = :"stub_http_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, opts, ref: ref, port: 0)
    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  def closed_url do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}"
  end
end
