package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/pion/webrtc/v4"

	"github.com/discordia-grupo01/voice-sfu/internal/events"
	contract "github.com/discordia-grupo01/voice-sfu/internal/events/events-contract"
	"github.com/discordia-grupo01/voice-sfu/internal/model"
	"github.com/discordia-grupo01/voice-sfu/internal/repository"
)

type VoiceService struct {
	api   *webrtc.API
	rooms repository.RoomRepository
	pub   events.Publisher
}

func NewVoiceService(api *webrtc.API, rooms repository.RoomRepository, pub events.Publisher) *VoiceService {
	return &VoiceService{api: api, rooms: rooms, pub: pub}
}

// Join crea la conexión WebRTC del participante (todavía sin audio).
func (s *VoiceService) Join(roomID, peerID string, send func(string, any)) error {
	s.Leave(roomID, peerID) // si ya estaba (reconexión), limpiamos lo anterior

	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return err
	}
	p := model.NewPeer(peerID, roomID, pc, send)
	s.rooms.Add(roomID, p)

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			send("candidate", c.ToJSON())
		}
	})
	pc.OnTrack(func(remote *webrtc.TrackRemote, _ *webrtc.RTPReceiver) { s.forward(p, remote) })
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		if st == webrtc.PeerConnectionStateFailed || st == webrtc.PeerConnectionStateClosed {
			s.Leave(roomID, peerID)
		}
	})

	s.emit(contract.VoiceParticipantJoined, roomID, peerID)
	return nil
}

// forward: llega el audio de un participante y se copia a todos los demás.
func (s *VoiceService) forward(pub *model.Peer, remote *webrtc.TrackRemote) {
	local, err := webrtc.NewTrackLocalStaticRTP(remote.Codec().RTPCodecCapability, "audio-"+pub.ID, pub.ID)
	if err != nil {
		return
	}
	pub.SetTrack(local)

	for _, other := range s.rooms.Others(pub.RoomID, pub.ID) {
		if other.AttachTrack(pub.ID, local) {
			other.Renegotiate()
		}
	}

	buf := make([]byte, 1500)
	for {
		n, _, err := remote.Read(buf)
		if err != nil {
			return
		}
		if _, err := local.Write(buf[:n]); err != nil && !errors.Is(err, io.ErrClosedPipe) {
			return
		}
		// TODO: leer el nivel de audio (RFC 6464) para el evento "speaking"
	}
}

// Leave cierra la conexión, avisa a los demás y borra la sala si quedó vacía.
func (s *VoiceService) Leave(roomID, peerID string) {
	p, empty := s.rooms.Remove(roomID, peerID)
	if p == nil {
		return
	}
	_ = p.PC.Close()

	for _, other := range s.rooms.Others(roomID, peerID) {
		if other.DetachTrack(peerID) {
			other.Renegotiate()
		}
	}

	s.emit(contract.VoiceParticipantLeft, roomID, peerID)
	if empty {
		s.emit(contract.VoiceChannelEmpty, roomID, "")
	}
}

func (s *VoiceService) HandleOffer(roomID, peerID, sdp string) error {
	p := s.rooms.Get(roomID, peerID)
	if p == nil {
		return fmt.Errorf("peer %s no está en la sala %s", peerID, roomID)
	}
	if err := p.PC.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: sdp}); err != nil {
		return err
	}
	answer, err := p.PC.CreateAnswer(nil)
	if err != nil {
		return err
	}
	if err := p.PC.SetLocalDescription(answer); err != nil {
		return err
	}
	p.Send("answer", map[string]string{"sdp": answer.SDP})

	// Que escuche a los que ya estaban hablando
	added := false
	for _, other := range s.rooms.Others(roomID, peerID) {
		if t := other.Track(); t != nil && p.AttachTrack(other.ID, t) {
			added = true
		}
	}
	if added {
		p.Renegotiate()
	}
	return nil
}

func (s *VoiceService) HandleAnswer(roomID, peerID, sdp string) error {
	p := s.rooms.Get(roomID, peerID)
	if p == nil {
		return fmt.Errorf("peer %s no está en la sala %s", peerID, roomID)
	}
	if err := p.PC.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: sdp}); err != nil {
		return err
	}
	p.OnAnswerApplied()
	return nil
}

func (s *VoiceService) HandleCandidate(roomID, peerID string, c webrtc.ICECandidateInit) error {
	p := s.rooms.Get(roomID, peerID)
	if p == nil {
		return fmt.Errorf("peer %s no está en la sala %s", peerID, roomID)
	}
	return p.PC.AddICECandidate(c)
}

// emit publica en RabbitMQ sin bloquear la señalización.
func (s *VoiceService) emit(routingKey, channelID, userID string) {
	ev := contract.VoiceEvent{ChannelID: channelID, UserID: userID, OccurredAt: time.Now().UTC()}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := s.pub.Publish(ctx, routingKey, ev); err != nil {
			log.Println("evento no publicado:", err)
		}
	}()
}
