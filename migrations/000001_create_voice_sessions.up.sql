CREATE TABLE voice_sessions (
    id         BIGSERIAL PRIMARY KEY,
    channel_id TEXT        NOT NULL,
    user_id    TEXT        NOT NULL,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at    TIMESTAMPTZ
);
CREATE INDEX idx_voice_sessions_channel ON voice_sessions (channel_id, joined_at);
