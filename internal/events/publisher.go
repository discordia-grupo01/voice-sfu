package events

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
)

type Publisher interface {
	Publish(ctx context.Context, routingKey string, payload any) error
}

// Noop: para desarrollo sin RabbitMQ.
type noop struct{}

func NewNoop() Publisher                                { return noop{} }
func (noop) Publish(context.Context, string, any) error { return nil }

type rabbit struct {
	mu       sync.Mutex
	ch       *amqp.Channel
	exchange string
}

func NewRabbit(url, exchange string) (Publisher, error) {
	conn, err := amqp.Dial(url)
	if err != nil {
		return nil, err
	}
	ch, err := conn.Channel()
	if err != nil {
		return nil, err
	}
	if err := ch.ExchangeDeclare(exchange, "topic", true, false, false, false, nil); err != nil {
		return nil, err
	}
	return &rabbit{ch: ch, exchange: exchange}, nil
}

func (r *rabbit) Publish(ctx context.Context, routingKey string, payload any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.ch.PublishWithContext(ctx, r.exchange, routingKey, false, false, amqp.Publishing{
		ContentType: "application/json",
		Body:        body,
		Timestamp:   time.Now(),
	})
}
