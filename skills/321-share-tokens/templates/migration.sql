-- Append as your next "-- N up" block (bump t/01-migration.t + truncate list).
-- Only the sha256 hash of a share token is stored; the raw token appears only
-- in the share URL. Tokens are revocable and optionally expiring.
CREATE TABLE share_tokens (
    share_token_id     BIGSERIAL PRIMARY KEY,
    token_hash         TEXT NOT NULL UNIQUE,
    resource_type      TEXT NOT NULL
                       CHECK (resource_type IN ('love_profile', 'role_spec', 'comparison')),
    resource_id        BIGINT NOT NULL,
    created_by_user_id BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    permission         TEXT NOT NULL DEFAULT 'view',
    expires_at         TIMESTAMPTZ,
    revoked_at         TIMESTAMPTZ,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX share_tokens_resource_idx ON share_tokens(resource_type, resource_id);
-- Adapt the CHECK list to YOUR resource types.
