package eventscontract

import "time"

const (
	VoiceParticipantJoined = "voice.participant.joined"
	VoiceParticipantLeft   = "voice.participant.left"
	VoiceChannelEmpty      = "voice.channel.empty"
)

type VoiceEvent struct {
	ChannelID  string    `json:"channel_id"`
	UserID     string    `json:"user_id,omitempty"` // vacío en voice.channel.empty
	OccurredAt time.Time `json:"occurred_at"`
}
