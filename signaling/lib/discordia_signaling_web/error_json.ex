defmodule DiscordiaSignalingWeb.ErrorJSON do
  @moduledoc """
  Errores que genera el framework (ruta inexistente, JSON mal formado, excepciones).
  Mapea el status del template al código textual del catálogo común.
  """

  alias DiscordiaSignalingWeb.ApiError

  def render(template, _assigns) do
    template
    |> status_from_template()
    |> ApiError.reason_for_status()
    |> ApiError.payload()
  end

  defp status_from_template(template) do
    with [status | _] <- String.split(template, "."),
         {code, ""} <- Integer.parse(status) do
      code
    else
      _ -> 500
    end
  end
end
