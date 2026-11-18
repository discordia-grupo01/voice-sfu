defmodule DiscordiaSignalingWeb.ApiErrorTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias DiscordiaSignalingWeb.ApiError

  @code_pattern ~r/^[A-Z][A-Z0-9_]*$/

  @reasons [
    :invalid_body,
    :unauthorized,
    :forbidden,
    :not_found,
    :method_not_allowed,
    :not_acceptable,
    :payload_too_large,
    :unsupported_media_type,
    :rate_limited,
    :internal_error,
    :bad_gateway,
    :service_unavailable,
    :gateway_timeout,
    :voice_forbidden,
    :voice_unavailable,
    :voice_not_configured,
    :voice_not_in_channel,
    :voice_screen_share_forbidden,
    :voice_call_forbidden,
    :call_not_found,
    :call_already_exists,
    :invalid_call_state
  ]

  test "every reason has a valid code, a message and a status of 400 or more" do
    for reason <- @reasons do
      assert %{error: %{code: code, message: message, details: %{}}} = ApiError.payload(reason)
      assert code =~ @code_pattern
      assert is_binary(message) and message != ""
      assert ApiError.http_status(reason) >= 400
    end
  end

  test "keeps the domain codes that clients already consume, in uppercase" do
    assert {"VOICE_FORBIDDEN", _} = ApiError.describe(:voice_forbidden)
    assert {"CALL_NOT_FOUND", _} = ApiError.describe(:call_not_found)
    assert {"VOICE_UNAVAILABLE", _} = ApiError.describe(:voice_unavailable)
    assert {"VOICE_NOT_CONFIGURED", _} = ApiError.describe(:voice_not_configured)
  end

  test "normalizes nil and non-map details to an empty object" do
    assert ApiError.payload(:forbidden, nil).error.details == %{}
    assert ApiError.payload(:forbidden, "texto").error.details == %{}
    assert ApiError.payload(:invalid_body, %{field: "channel_id"}).error.details == %{field: "channel_id"}
  end

  test "an unknown reason never crashes: it becomes INTERNAL_ERROR with status 500" do
    assert %{error: %{code: "INTERNAL_ERROR"}} = ApiError.payload({:error, :bad_request})
    assert ApiError.http_status(:algo_raro) == 500
  end

  test "send_error responds with the envelope as JSON and halts" do
    conn = ApiError.send_error(conn(:get, "/"), :forbidden)

    assert conn.halted
    assert conn.status == 403
    DiscordiaSignaling.TestHelpers.assert_error(conn, "FORBIDDEN")
  end
end
