defmodule DiscordiaSignalingWeb.ErrorJSONTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignalingWeb.ErrorJSON

  test "renders Phoenix errors as JSON" do
    assert ErrorJSON.render("404.html", %{}) == %{errors: %{detail: "Not Found"}}
    assert ErrorJSON.render("500.html", %{}) == %{errors: %{detail: "Internal Server Error"}}
  end
end
