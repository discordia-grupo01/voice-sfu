defmodule DiscordiaSignaling.Readiness do
  alias DiscordiaSignaling.Voice.LiveKitRoomService
  alias DiscordiaSignaling.Voice.VoiceAccess

  @check_timeout_ms 1_500

  @spec check() :: :ok | {:error, [String.t()]}
  def check do
    checks = checks()

    failed =
      checks
      |> Task.async_stream(fn {_name, fun} -> fun.() end,
        timeout: @check_timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(checks)
      |> Enum.flat_map(fn
        {{:ok, :ok}, _check} -> []
        {_result, {name, _fun}} -> [name]
      end)

    if failed == [], do: :ok, else: {:error, failed}
  end

  defp checks do
    base = [{"livekit", &LiveKitRoomService.ping/0}]

    if VoiceAccess.authz_mode() == "servers_api" do
      base ++ [{"servers", &servers_reachable/0}]
    else
      base
    end
  end

  defp servers_reachable do
    case Application.get_env(:discordia_signaling, :servers, [])[:url] do
      base when is_binary(base) and base != "" ->
        url = String.to_charlist(String.trim_trailing(base, "/") <> "/livez")

        case :httpc.request(
               :get,
               {url, []},
               [connect_timeout: 1_000, timeout: @check_timeout_ms],
               body_format: :binary
             ) do
          {:ok, {{_, 200, _}, _headers, _body}} -> :ok
          _other -> {:error, :unavailable}
        end

      _missing ->
        {:error, :not_configured}
    end
  end
end
