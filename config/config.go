package config

import (
	"os"
	"strconv"
)

type Config struct {
	HTTPPort       string
	UDPPort        int
	PublicIP       string
	InternalToken  string
	RabbitURL      string
	EventsExchange string
	Environment    string
	Host           string
}

func Load() Config {
	udp, _ := strconv.Atoi(get("UDP_PORT", "50000"))
	return Config{
		HTTPPort:       get("HTTP_PORT", "8080"),
		UDPPort:        udp,
		PublicIP:       get("PUBLIC_IP", "127.0.0.1"),
		InternalToken:  get("INTERNAL_TOKEN", ""),
		RabbitURL:      get("RABBITMQ_URL", ""),
		EventsExchange: get("EVENTS_EXCHANGE", "discordia.events"),
		Environment:    get("ENVIRONMENT", "development"),
		Host:           get("HOST", "0.0.0.0"),
	}
}

func get(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
