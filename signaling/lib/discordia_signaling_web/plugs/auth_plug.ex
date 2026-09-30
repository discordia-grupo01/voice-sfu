defmodule DiscordiaSignalingWeb.AuthPlug do
  @moduledoc """
  Authenticates the token endpoint with the same HS256 JWT contract as identify.

  Kong normally validates the JWT before requests reach this service. Direct
  JWT verification keeps local development and direct service checks honest.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case authenticated_user_id(conn) do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()

      user_id ->
        assign(conn, :current_user_id, user_id)
    end
  end

  defp authenticated_user_id(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> verify_access_token(token)
      _ -> development_user_id(conn)
    end
  end

  defp verify_access_token(token) do
    secret = System.get_env("JWT_SECRET", "")

    if secret == "" do
      nil
    else
      jwk = JOSE.JWK.from_oct(secret)

      try do
        case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
          {true, jwt, _jws} -> claims_user_id(Map.get(jwt, :fields, %{}))
          _ -> nil
        end
      rescue
        _ -> nil
      end
    end
  end

  defp claims_user_id(%{"sub" => user_id, "exp" => expires_at})
       when is_binary(user_id) and user_id != "" and is_integer(expires_at) do
    if expires_at > System.system_time(:second), do: user_id
  end

  defp claims_user_id(_claims), do: nil

  defp development_user_id(conn) do
    if Mix.env() == :prod do
      nil
    else
      case get_req_header(conn, "x-user-id") do
        [user_id] when user_id != "" -> user_id
        _ -> nil
      end
    end
  end
end
