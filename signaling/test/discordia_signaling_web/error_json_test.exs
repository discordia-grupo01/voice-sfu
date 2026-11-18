defmodule DiscordiaSignalingWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignalingWeb.ErrorJSON

  @code_pattern ~r/^[A-Z][A-Z0-9_]*$/

  test "renders the framework templates with the textual catalog code" do
    expected = %{
      "400.json" => "INVALID_BODY",
      "401.json" => "UNAUTHORIZED",
      "403.json" => "FORBIDDEN",
      "404.json" => "NOT_FOUND",
      "405.json" => "METHOD_NOT_ALLOWED",
      "406.json" => "NOT_ACCEPTABLE",
      "413.json" => "PAYLOAD_TOO_LARGE",
      "415.json" => "UNSUPPORTED_MEDIA_TYPE",
      "500.json" => "INTERNAL_ERROR",
      "503.json" => "SERVICE_UNAVAILABLE"
    }

    for {template, code} <- expected do
      assert %{error: %{code: ^code, message: message, details: details}} =
               ErrorJSON.render(template, %{})

      assert code =~ @code_pattern
      assert is_binary(message) and message != ""
      assert details == %{}
    end
  end

  test "an unknown template falls back to INTERNAL_ERROR" do
    assert %{error: %{code: "INTERNAL_ERROR"}} = ErrorJSON.render("template.json", %{})
  end
end
