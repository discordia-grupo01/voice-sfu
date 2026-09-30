package main

import (
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/discordia-grupo01/voice-sfu/config"
	"github.com/discordia-grupo01/voice-sfu/internal/events"
	"github.com/discordia-grupo01/voice-sfu/internal/handler"
	"github.com/discordia-grupo01/voice-sfu/internal/middleware"
	"github.com/discordia-grupo01/voice-sfu/internal/repository"
	"github.com/discordia-grupo01/voice-sfu/internal/service"
)

func main() {
	cfg := config.Load()
	if cfg.InternalToken == "" {
		log.Println("ATENCIÓN: INTERNAL_TOKEN vacío, cualquiera con acceso a la red puede usar el SFU")
	}

	api, err := service.NewWebRTCAPI(cfg)
	if err != nil {
		log.Fatal(err)
	}

	svc := service.NewVoiceService(api, repository.NewMemoryRoomRepository(), newPublisher(cfg))
	signal := handler.NewSignalHandler(svc)

	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery())

	// /livez: solo confirma que el proceso esta vivo. No toca la BDD.
	router.GET("/livez", func(c *gin.Context) {
		c.String(http.StatusOK, "ok")
	})
	// /readyz: confirma que el servicio puede operar (chequear BDD aca).
	router.GET("/readyz", func(c *gin.Context) {
		// TODO: chequear conexion a Postgres antes de responder 200
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	})
	router.GET("/", func(c *gin.Context) {
		c.String(http.StatusOK, "discordia-SFU up")
	})

	router.GET("/ws", middleware.InternalAuth(cfg.InternalToken), signal.ServeWS)

	addr := cfg.Host + ":" + cfg.HTTPPort
	log.Printf("listening on %s", addr)
	log.Fatal(router.Run(addr))
}

// Si RabbitMQ no responde, la voz sigue funcionando sin publicar eventos.
func newPublisher(cfg config.Config) events.Publisher {
	if cfg.RabbitURL == "" {
		return events.NewNoop()
	}
	for i := 1; i <= 10; i++ {
		p, err := events.NewRabbit(cfg.RabbitURL, cfg.EventsExchange)
		if err == nil {
			return p
		}
		log.Printf("RabbitMQ no disponible (intento %d/10): %v", i, err)
		time.Sleep(2 * time.Second)
	}
	log.Println("sigo sin publicar eventos")
	return events.NewNoop()
}
