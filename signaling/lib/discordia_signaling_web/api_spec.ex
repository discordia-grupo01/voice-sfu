defmodule DiscordiaSignalingWeb.ApiSpec do
  @moduledoc "Contrato OpenAPI del signaling de voz, generado desde el router y los controladores."

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl true
  def spec(_opts \\ []) do
    %OpenApi{
      servers: [Server.from_endpoint(DiscordiaSignalingWeb.Endpoint)],
      info: %Info{
        title: "Discordia - Voice Signaling API",
        description:
          "Señalización de voz sobre LiveKit: emite los tokens para entrar a un canal de voz o " <>
            "compartir pantalla, maneja las llamadas privadas uno a uno y expone quién está " <>
            "conectado. La media viaja por LiveKit; la presencia en vivo, por el socket de " <>
            "Phoenix (`/voice/socket`), fuera de este contrato. Los errores de este servicio " <>
            "son `{\"error\": \"<codigo>\"}`.",
        version: "1.0.0"
      },
      paths: Paths.from_router(DiscordiaSignalingWeb.Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT",
            description:
              "JWT HS256 firmado con JWT_SECRET (el mismo contrato que identify), con `sub` y `exp`."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
