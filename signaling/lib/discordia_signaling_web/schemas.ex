defmodule DiscordiaSignalingWeb.Schemas do
  @moduledoc "Esquemas OpenAPI de la API de señalización de voz."

  alias OpenApiSpex.Schema

  defmodule ErrorDetail do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorDetail",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          pattern: "^[A-Z][A-Z0-9_]*$",
          description:
            "Código estable en SCREAMING_SNAKE_CASE: los clientes deciden por este campo.",
          example: "VOICE_FORBIDDEN"
        },
        message: %Schema{
          type: :string,
          minLength: 1,
          description: "Texto legible para humanos.",
          example: "No tenés acceso a este canal de voz."
        },
        details: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "Datos adicionales; `{}` si no hay. En un 400 `INVALID_BODY`, `field` y `reason` indican el campo."
        }
      },
      required: [:code, :message, :details]
    })
  end

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Sobre de error común a todos los servicios de Discordia.",
      type: :object,
      properties: %{
        error: ErrorDetail
      },
      required: [:error],
      additionalProperties: false
    })
  end

  defmodule Health do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Health",
      type: :object,
      properties: %{
        status: %Schema{type: :string, example: "ok"}
      },
      required: [:status]
    })
  end

  defmodule NotReady do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NotReady",
      type: :object,
      properties: %{
        status: %Schema{type: :string, example: "unavailable"},
        failed: %Schema{
          type: :array,
          description: "Dependencias que fallaron.",
          items: %Schema{type: :string, enum: ["livekit", "servers", "replica_database"]}
        }
      },
      required: [:status, :failed]
    })
  end

  defmodule ChannelRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelRequest",
      type: :object,
      properties: %{
        channel_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Canal de voz. La sala de LiveKit se llama `voice:<channel_id>`.",
          example: "550e8400-e29b-41d4-a716-446655440000"
        }
      },
      required: [:channel_id]
    })
  end

  defmodule VoiceToken do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "VoiceToken",
      type: :object,
      properties: %{
        identity: %Schema{type: :string, example: "user-42"},
        name: %Schema{type: :string, example: "Ada"},
        room_name: %Schema{
          type: :string,
          example: "voice:550e8400-e29b-41d4-a716-446655440000"
        },
        token: %Schema{type: :string, description: "JWT de LiveKit firmado para la sala."},
        url: %Schema{type: :string, example: "ws://localhost:7880"}
      },
      required: [:identity, :name, :room_name, :token, :url]
    })
  end

  defmodule ScreenToken do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ScreenToken",
      type: :object,
      properties: %{
        identity: %Schema{type: :string, example: "user-42:screen"},
        room_name: %Schema{type: :string, example: "voice:550e8400-e29b-41d4-a716-446655440000"},
        token: %Schema{
          type: :string,
          description: "JWT de LiveKit que solo puede publicar screen_share y screen_share_audio."
        },
        url: %Schema{type: :string, example: "ws://localhost:7880"}
      },
      required: [:identity, :room_name, :token, :url]
    })
  end

  defmodule CallRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CallRequest",
      type: :object,
      properties: %{
        recipient_id: %Schema{
          type: :string,
          minLength: 1,
          description: "Usuario al que se llama."
        },
        conversation_id: %Schema{
          type: :string,
          minLength: 1,
          nullable: true,
          description:
            "Conversación directa existente. Puede omitirse para abrir una conversación desde un borrador."
        }
      },
      required: [:recipient_id]
    })
  end

  defmodule Call do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Call",
      type: :object,
      properties: %{
        call_id: %Schema{type: :string},
        conversation_id: %Schema{type: :string},
        caller_id: %Schema{type: :string},
        recipient_id: %Schema{type: :string},
        room_name: %Schema{type: :string, example: "private-call:abc123"},
        status: %Schema{type: :string, enum: ["ringing"], example: "ringing"}
      },
      required: [:call_id, :conversation_id, :caller_id, :recipient_id, :room_name, :status]
    })
  end

  defmodule AcceptedCall do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AcceptedCall",
      description: "La llamada aceptada con las credenciales de LiveKit de quien acepta.",
      type: :object,
      properties: %{
        call_id: %Schema{type: :string},
        conversation_id: %Schema{type: :string},
        caller_id: %Schema{type: :string},
        recipient_id: %Schema{type: :string},
        room_name: %Schema{type: :string, example: "private-call:abc123"},
        status: %Schema{type: :string, enum: ["active"], example: "active"},
        token: %Schema{type: :string, description: "JWT de LiveKit firmado para la sala."},
        url: %Schema{type: :string, example: "ws://localhost:7880"}
      },
      required: [
        :call_id,
        :conversation_id,
        :caller_id,
        :recipient_id,
        :room_name,
        :status,
        :token,
        :url
      ]
    })
  end

  defmodule Participant do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Participant",
      type: :object,
      properties: %{
        participant_id: %Schema{type: :string},
        name: %Schema{type: :string}
      },
      required: [:participant_id, :name]
    })
  end

  defmodule ChannelPresence do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelPresence",
      type: :object,
      properties: %{
        channel_id: %Schema{type: :string},
        started_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Cuándo arrancó la sala; `null` si no se conoce."
        },
        participants: %Schema{type: :array, items: Participant}
      },
      required: [:channel_id, :started_at, :participants]
    })
  end

  defmodule Presence do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Presence",
      type: :object,
      properties: %{
        server_id: %Schema{type: :string},
        channels: %Schema{type: :array, items: ChannelPresence}
      },
      required: [:server_id, :channels]
    })
  end

  defmodule SocketTicket do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SocketTicket",
      type: :object,
      properties: %{
        ticket: %Schema{
          type: :string,
          description: "JWT de vida corta para abrir el socket de presencia de voz."
        },
        expires_in: %Schema{type: :integer, description: "Segundos de validez.", example: 30}
      },
      required: [:ticket, :expires_in]
    })
  end
end
