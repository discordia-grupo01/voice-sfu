defmodule DiscordiaSignaling.Events.RabbitMQ do
  @moduledoc false

  @connect_timeout 3_000

  @spec open(String.t()) :: {:ok, AMQP.Connection.t()} | {:error, term()}
  def open(url) when is_binary(url) do
    AMQP.Connection.open(url, connection_options(url))
  end

  @spec connection_options(String.t()) :: keyword()
  def connection_options(url) when is_binary(url) do
    base = [connection_timeout: @connect_timeout]

    if URI.parse(url).scheme == "amqps" do
      Keyword.put(base, :ssl_options, tls_options(url))
    else
      base
    end
  end

  defp tls_options(url) do
    host = URI.parse(url).host |> String.to_charlist()

    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
