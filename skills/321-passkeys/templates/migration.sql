-- Append as the next "-- N up" block in your Mojo::Pg migrations file
-- (e.g. db/migration.sql). Bump N to one past your current latest version,
-- and update any "schema is at version N" test. Adjust users(user_id) to your
-- actual users PK column if it differs.

-- N up
CREATE TABLE webauthn_credentials (
    credential_id  TEXT PRIMARY KEY,            -- base64url of the raw credential id
    user_id        BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    public_key     TEXT NOT NULL,               -- COSE key, base64url, exactly as Authen::WebAuthn emits
    sign_count     BIGINT NOT NULL DEFAULT 0,
    transports     TEXT,                         -- optional JSON array (usb/nfc/ble/internal/hybrid)
    aaguid         TEXT,
    label          TEXT,                         -- "MacBook Touch ID" etc.
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at   TIMESTAMPTZ
);
CREATE INDEX webauthn_credentials_user_id_idx ON webauthn_credentials(user_id);

-- Opaque, stable WebAuthn user.id (NEVER the email or PK). Enables discoverable
-- ("usernameless") sign-in and keeps identity private across email changes.
ALTER TABLE users ADD COLUMN webauthn_user_handle TEXT UNIQUE;
