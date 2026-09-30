package service

import (
	"net"

	"github.com/pion/webrtc/v4"

	"github.com/discordia-grupo01/voice-sfu/config"
)

func NewWebRTCAPI(cfg config.Config) (*webrtc.API, error) {
	udp, err := net.ListenUDP("udp", &net.UDPAddr{Port: cfg.UDPPort})
	if err != nil {
		return nil, err
	}
	se := webrtc.SettingEngine{}
	se.SetICEUDPMux(webrtc.NewICEUDPMux(nil, udp)) // un solo puerto UDP para todos
	// IP que los navegadores van a usar para llegar a este SFU
	se.SetNAT1To1IPs([]string{cfg.PublicIP}, webrtc.ICECandidateTypeHost)

	me := &webrtc.MediaEngine{}
	if err := me.RegisterDefaultCodecs(); err != nil { // incluye Opus
		return nil, err
	}
	return webrtc.NewAPI(webrtc.WithSettingEngine(se), webrtc.WithMediaEngine(me)), nil
}
