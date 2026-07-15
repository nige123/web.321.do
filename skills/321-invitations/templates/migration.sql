-- Migration 5: organisation_invitations - invite a teammate to an organisation
-- by email, accept (granting the role), or revoke. Tokens expire after 7 days.
--
-- Indexes (321-db-speed): `token UNIQUE` is the accept path's lookup; the
-- org FK index serves the Team page's pending list and the org cascade.

CREATE TABLE IF NOT EXISTS organisation_invitations (
    invitation_id      BIGSERIAL PRIMARY KEY,
    organisation_id    BIGINT NOT NULL REFERENCES organisations(organisation_id) ON DELETE CASCADE,
    email              TEXT NOT NULL,
    role               TEXT NOT NULL,
    token              TEXT NOT NULL UNIQUE,
    invited_by_user_id BIGINT REFERENCES axs_identity.users(user_id) ON DELETE SET NULL,
    accepted_at        TIMESTAMPTZ,
    revoked_at         TIMESTAMPTZ,
    expires_at         TIMESTAMPTZ NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS organisation_invitations_org_idx ON organisation_invitations(organisation_id);
