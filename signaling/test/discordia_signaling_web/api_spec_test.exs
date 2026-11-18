defmodule DiscordiaSignalingWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignalingWeb.ApiSpec

  @operations [
    {"/livez", :get},
    {"/readyz", :get},
    {"/api/voice/token", :post},
    {"/api/voice/calls", :post},
    {"/api/voice/calls/{id}/accept", :post},
    {"/api/voice/calls/{id}/reject", :post},
    {"/api/voice/calls/{id}/finish", :post},
    {"/api/voice/calls/{id}/screen-token", :post},
    {"/api/voice/screen-token", :post},
    {"/api/voice/session", :delete},
    {"/api/voice/participants", :get},
    {"/api/voice/socket-ticket", :post}
  ]

  test "the contract covers the 12 operations of the router" do
    spec = ApiSpec.spec()

    for {path, method} <- @operations do
      assert Map.get(spec.paths[path], method), "missing #{method} #{path}"
    end

    assert map_size(spec.paths) == 12
  end

  test "declares the bearer scheme" do
    assert %{"bearerAuth" => %{scheme: "bearer"}} = ApiSpec.spec().components.securitySchemes
  end

  test "private call requests allow an omitted or explicit conversation" do
    spec = ApiSpec.spec()
    request = spec.components.schemas["CallRequest"]

    assert request.required == [:recipient_id]
    assert Map.has_key?(request.properties, :conversation_id)
  end
end
