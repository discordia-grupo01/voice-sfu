package model

import (
	"sync"

	"github.com/pion/webrtc/v4"
)

// Peer = un participante conectado al SFU.
type Peer struct {
	ID     string
	RoomID string
	PC     *webrtc.PeerConnection
	Send   func(typ string, data any) // manda un mensaje a voice-signaling

	mu      sync.Mutex
	track   *webrtc.TrackLocalStaticRTP  // el audio que este peer publica
	senders map[string]*webrtc.RTPSender // audio de otros que recibe: publicador -> sender
	pending bool                         // hay una renegociación esperando
}

func NewPeer(id, roomID string, pc *webrtc.PeerConnection, send func(string, any)) *Peer {
	return &Peer{ID: id, RoomID: roomID, PC: pc, Send: send, senders: map[string]*webrtc.RTPSender{}}
}

func (p *Peer) SetTrack(t *webrtc.TrackLocalStaticRTP) {
	p.mu.Lock()
	p.track = t
	p.mu.Unlock()
}

func (p *Peer) Track() *webrtc.TrackLocalStaticRTP {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.track
}

// AttachTrack: empieza a enviarle a este peer el audio de otro. true si agregó algo.
func (p *Peer) AttachTrack(fromPeerID string, t *webrtc.TrackLocalStaticRTP) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.senders[fromPeerID]; ok {
		return false
	}
	s, err := p.PC.AddTrack(t)
	if err != nil {
		return false
	}
	p.senders[fromPeerID] = s
	// Hay que leer el RTCP del sender aunque no lo usemos, o Pion acumula paquetes.
	go func() {
		buf := make([]byte, 1500)
		for {
			if _, _, err := s.Read(buf); err != nil {
				return
			}
		}
	}()
	return true
}

// DetachTrack: deja de enviarle el audio de otro (porque se fue).
func (p *Peer) DetachTrack(fromPeerID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	s, ok := p.senders[fromPeerID]
	if !ok {
		return false
	}
	delete(p.senders, fromPeerID)
	return p.PC.RemoveTrack(s) == nil
}

// Renegotiate: pide al navegador una nueva negociación (cambió la lista de audios).
// Si hay una negociación en curso, espera a que termine para no pisarla.
func (p *Peer) Renegotiate() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.PC.SignalingState() != webrtc.SignalingStateStable {
		p.pending = true
		return
	}
	offer, err := p.PC.CreateOffer(nil)
	if err != nil {
		return
	}
	if err := p.PC.SetLocalDescription(offer); err != nil {
		return
	}
	p.Send("offer", map[string]string{"sdp": offer.SDP})
}

// OnAnswerApplied: se llama cuando el navegador contestó; si quedó algo pendiente, renegocia.
func (p *Peer) OnAnswerApplied() {
	p.mu.Lock()
	again := p.pending
	p.pending = false
	p.mu.Unlock()
	if again {
		p.Renegotiate()
	}
}
