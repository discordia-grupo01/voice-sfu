package repository

import (
	"sync"

	"github.com/discordia-grupo01/voice-sfu/internal/model"
)

type RoomRepository interface {
	Add(roomID string, p *model.Peer)
	Get(roomID, peerID string) *model.Peer
	Others(roomID, exceptPeerID string) []*model.Peer
	// Remove devuelve el peer quitado (nil si no estaba) y si la sala quedó vacía.
	Remove(roomID, peerID string) (removed *model.Peer, roomEmpty bool)
}

type memoryRoomRepository struct {
	mu    sync.RWMutex
	rooms map[string]map[string]*model.Peer
}

func NewMemoryRoomRepository() RoomRepository {
	return &memoryRoomRepository{rooms: map[string]map[string]*model.Peer{}}
}

func (r *memoryRoomRepository) Add(roomID string, p *model.Peer) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rooms[roomID] == nil {
		r.rooms[roomID] = map[string]*model.Peer{}
	}
	r.rooms[roomID][p.ID] = p
}

func (r *memoryRoomRepository) Get(roomID, peerID string) *model.Peer {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.rooms[roomID][peerID]
}

func (r *memoryRoomRepository) Others(roomID, except string) []*model.Peer {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []*model.Peer
	for id, p := range r.rooms[roomID] {
		if id != except {
			out = append(out, p)
		}
	}
	return out
}

func (r *memoryRoomRepository) Remove(roomID, peerID string) (*model.Peer, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.rooms[roomID][peerID]
	if !ok {
		return nil, false
	}
	delete(r.rooms[roomID], peerID)
	empty := len(r.rooms[roomID]) == 0
	if empty {
		delete(r.rooms, roomID) // Salir CA 2: canal vacío, sala borrada y lista para reusarse
	}
	return p, empty
}
