defmodule DiscordiaSignaling.Events.RabbitMQTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Events.RabbitMQ

  test "uses the connection timeout without TLS for amqp URLs" do
    options = RabbitMQ.connection_options("amqp://localhost:5672")

    assert options[:connection_timeout] == 3_000
    refute Keyword.has_key?(options, :ssl_options)
  end

  test "enables peer verification and hostname checks for amqps URLs" do
    options = RabbitMQ.connection_options("amqps://broker.example.com/vhost")
    ssl_options = options[:ssl_options]

    assert options[:connection_timeout] == 3_000
    assert ssl_options[:verify] == :verify_peer
    assert is_list(ssl_options[:cacerts])
    assert ssl_options[:server_name_indication] == ~c"broker.example.com"

    assert is_function(ssl_options[:customize_hostname_check][:match_fun], 2)
  end
end
