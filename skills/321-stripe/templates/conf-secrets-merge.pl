# 321-stripe skill template — port into <app>'s conf/production.conf ; see SKILL.md
#
# This is the Stripe-config + git-ignored-secrets pattern from production.conf.
# The price_id / meter / portal_return_url are NOT secret and stay in this file.
# The secret_key + webhook_secret are LIVE secrets: leave them empty here and let
# them load from the git-ignored conf/secrets.local.conf on the production host
# (see the merge block at the bottom).

my $config = {
    moniker                 => '<app>.web',
    base_url                => 'https://<app>.com',
    domain                  => '<app>.com',
    # ... your other config (db_connect_string, cookie_secrets, email, etc.) ...

    # Stripe. The secret_key + webhook_secret are NOT committed - they load from
    # the git-ignored conf/secrets.local.conf (LIVE keys on the production host).
    # The rest are not secret and stay here.
    stripe_secret_key        => '',  # rk_live_… (overridden by conf/secrets.local.conf)
    stripe_webhook_secret    => '',  # whsec_…   (overridden by conf/secrets.local.conf)
    stripe_price_id          => '',  # price_…   LIVE metered price (set per app)
    stripe_meter             => '<app>_active_user',
    stripe_portal_return_url => 'https://<app>.com',
};

# Merge git-ignored local secrets (Stripe keys, etc.) if present on this host.
if ($ENV{MOJO_HOME} && -r "$ENV{MOJO_HOME}/conf/secrets.local.conf") {
    my $extra = do "$ENV{MOJO_HOME}/conf/secrets.local.conf";
    %$config = (%$config, %$extra) if ref $extra eq 'HASH';
}

$config;
