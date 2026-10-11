defmodule DiscordiaSignaling.Voice.SfuBridge do
  @moduledoc """
  Boundary for the internal signaling transport to the Go SFU.

  The transport is intentionally not implemented yet. Choose gRPC or a
  private TCP protocol only after defining authentication, framing, retries,
  and backpressure for the two services.
  """

  @spec forward(map()) :: :ok | {:error, atom()}
  def forward(_message), do: {:error, :not_configured}
end
