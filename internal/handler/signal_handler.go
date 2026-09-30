package handler

import (
	"encoding/json"
	"log"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"

	"github.com/discordia-grupo01/voice-sfu/internal/model"
	"github.com/discordia-grupo01/voice-sfu/internal/service"
)

type SignalHandler struct {
	svc      *service.VoiceService
	upgrader websocket.Upgrader
}

func NewSignalHandler(svc *service.VoiceService) *SignalHandler {
	return &SignalHandler{svc: svc}
}

type peerKey struct{ room, peer string }

func (h *SignalHandler) ServeWS(c *gin.Context) {
	conn, err := h.upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	var wmu sync.Mutex // gorilla/websocket solo permite un escritor a la vez
	sender := func(room, peer string) func(string, any) {
		return func(typ string, data any) {
			raw, _ := json.Marshal(data)
			wmu.Lock()
			defer wmu.Unlock()
			_ = conn.WriteJSON(model.Message{Type: typ, RoomID: room, PeerID: peer, Data: raw})
		}
	}

	// Si se cae la conexión con signaling, sacamos a todos los que entraron por ella.
	joined := map[peerKey]struct{}{}
	defer func() {
		for k := range joined {
			h.svc.Leave(k.room, k.peer)
		}
	}()

	for {
		var m model.Message
		if err := conn.ReadJSON(&m); err != nil {
			return
		}
		key := peerKey{m.RoomID, m.PeerID}

		var herr error
		switch m.Type {
		case "join":
			if herr = h.svc.Join(m.RoomID, m.PeerID, sender(m.RoomID, m.PeerID)); herr == nil {
				joined[key] = struct{}{}
			}
		case "leave":
			h.svc.Leave(m.RoomID, m.PeerID)
			delete(joined, key)
		case "offer", "answer":
			var d model.SDPPayload
			if herr = json.Unmarshal(m.Data, &d); herr == nil {
				if m.Type == "offer" {
					herr = h.svc.HandleOffer(m.RoomID, m.PeerID, d.SDP)
				} else {
					herr = h.svc.HandleAnswer(m.RoomID, m.PeerID, d.SDP)
				}
			}
		case "candidate":
			var c webrtc.ICECandidateInit
			if herr = json.Unmarshal(m.Data, &c); herr == nil {
				herr = h.svc.HandleCandidate(m.RoomID, m.PeerID, c)
			}
		}
		if herr != nil {
			log.Printf("%s (%s/%s): %v", m.Type, m.RoomID, m.PeerID, herr)
		}
	}
}
