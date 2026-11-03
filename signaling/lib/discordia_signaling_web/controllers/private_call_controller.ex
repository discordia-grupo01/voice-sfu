defmodule DiscordiaSignalingWeb.PrivateCallController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.PrivateCall

  def create(conn, %{"recipient_id" => recipient_id, "conversation_id" => conversation_id}) do
    auth = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    case PrivateCall.start(
           conn.assigns.current_user_id,
           recipient_id,
           conversation_id,
           auth
         ) do
      {:ok, call} -> conn |> put_status(201) |> json(payload(call))
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _), do: error(conn, :invalid_input)

  def accept(conn, %{"id" => call_id}) do
    auth = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    case PrivateCall.accept(call_id, conn.assigns.current_user_id, auth) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> error(conn, reason)
    end
  end

  def reject(conn, %{"id" => call_id}), do: action(conn, call_id, :reject)
  def finish(conn, %{"id" => call_id}), do: action(conn, call_id, :finish)

  defp action(conn, call_id, :reject) do
    case PrivateCall.reject(call_id, conn.assigns.current_user_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp action(conn, call_id, :finish) do
    case PrivateCall.finish(call_id, conn.assigns.current_user_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp payload(call) when is_map(call) do
    %{
      "call_id" => call.id,
      "conversation_id" => call.conversation_id,
      "caller_id" => call.caller_id,
      "recipient_id" => call.recipient_id,
      "room_name" => call.room_name,
      "status" => Atom.to_string(call.status)
    }
  end

  defp error(conn, :invalid_input), do: conn |> put_status(400) |> json(%{error: "invalid_input"})

  defp error(conn, :forbidden),
    do: conn |> put_status(403) |> json(%{error: "voice_call_forbidden"})

  defp error(conn, :call_not_found),
    do: conn |> put_status(404) |> json(%{error: "call_not_found"})

  defp error(conn, :call_already_exists),
    do: conn |> put_status(409) |> json(%{error: "call_already_exists"})

  defp error(conn, :invalid_call_state),
    do: conn |> put_status(409) |> json(%{error: "invalid_call_state"})

  defp error(conn, :not_configured),
    do: conn |> put_status(503) |> json(%{error: "voice_unavailable"})

  defp error(conn, _reason), do: conn |> put_status(403) |> json(%{error: "voice_call_forbidden"})
end
