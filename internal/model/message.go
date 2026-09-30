package model

import "encoding/json"

// Formato de todos los mensajes entre voice-signaling y voice-sfu.
// Type: join | leave | offer | answer | candidate
type Message struct {
	Type   string          `json:"type"`
	RoomID string          `json:"room_id"`
	PeerID string          `json:"peer_id"`
	Data   json.RawMessage `json:"data,omitempty"`
}

type SDPPayload struct {
	SDP string `json:"sdp"`
}
