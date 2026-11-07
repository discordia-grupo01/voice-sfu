defmodule DiscordiaSignalingWeb.RequestLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignalingWeb.Endpoint

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    TestHelpers.put_livekit_config()

    on_exit(fn ->
      Logger.configure(level: previous)

      if previous_mode,
        do: System.put_env("VOICE_AUTHZ_MODE", previous_mode),
        else: System.delete_env("VOICE_AUTHZ_MODE")
    end)

    :ok
  end

  @channel "550e8400-e29b-41d4-a716-446655440000"

  defp entries(log), do: log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp token_request(query \\ "") do
    conn(:post, "/api/voice/token" <> query, Jason.encode!(%{"channel_id" => @channel}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-user-id", "user-42")
    |> Endpoint.call([])
  end

  test "a real request is logged with its route pattern and who made it" do
    log = capture_log([level: :debug], fn -> token_request() end)

    assert %{
             "route" => "/api/voice/token",
             "method" => "POST",
             "status" => 200,
             "user_id" => "user-42"
           } = Enum.find(entries(log), &(&1["message"] == "http_request"))
  end

  test "neither the query string nor the issued token reach the logs" do
    log = capture_log([level: :debug], fn -> token_request("?ticket=SECRET-TICKET") end)

    refute log =~ "SECRET-TICKET"
    refute log =~ "eyJ"
    refute log =~ @channel
  end

  test "the request id travels with the line of the request" do
    log = capture_log([level: :debug], fn -> token_request() end)

    assert %{"request_id" => id} = Enum.find(entries(log), &(&1["message"] == "http_request"))
    assert is_binary(id)
  end

  test "an unknown route is logged without its path" do
    log =
      capture_log([level: :debug], fn ->
        conn(:get, "/no/existe/#{@channel}") |> Endpoint.call([])
      end)

    assert %{"route" => "unmatched", "status" => 404} =
             Enum.find(entries(log), &(&1["message"] == "http_request"))

    refute log =~ @channel
  end

  test "no line is plain text: everything the request writes is JSON" do
    log = capture_log([level: :debug], fn -> token_request() end)

    assert log != ""

    for line <- String.split(log, "\n", trim: true),
        do: assert(%{"level" => _} = Jason.decode!(line))

    refute log =~ "Processing with"
    refute log =~ "Parameters"
  end
end
