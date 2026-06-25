# Stripe-side setup runbook

Do this **once per environment**: first in **test** mode (on the dev host), then
in **live** mode (on the prod host). The code is environment-agnostic; only the
keys, object IDs, and webhook target differ. `<app>` = the app's short name;
`<app>_active_user` = the meter event name in your config (`stripe_meter`).

Everything here uses **restricted keys** (`rk_`) and a **git-ignored**
`conf/secrets.local.conf`. Never an `sk_` key. Never commit a key.

---

## 0. The restricted key (the human step)

You cannot create a restricted key via the API - the user makes it in the
dashboard. Ask for one with these scopes (everything else **None**):

**To build the objects (one-time) AND run the app:**
- Write: Products, Prices, Billing Meters, Webhook Endpoints, Customers,
  Checkout Sessions, Customer portal, Meter Event Stream
- Read: Subscriptions

Test key page: `dashboard.stripe.com/test/apikeys`. Live: toggle **off** test
mode, then `dashboard.stripe.com/apikeys`. One key (`rk_test_…` / `rk_live_…`)
serves both object-creation and runtime. A Stripe **Organization** is just a
container; keys are per-account within it.

> The key authenticates via HTTP basic auth: `curl -u "$RK:"` (key as username,
> empty password). A `403` like "does not have the required permissions for this
> endpoint" means a scope is missing, not that the key is wrong.

Keep the key in a shell variable for the build; the only place it persists is
the per-host secrets file (step 4). On the prod host, read it back with:
`RK=$(ssh PROD 'perl -e "my \$c=do q(/path/conf/secrets.local.conf); print \$c->{stripe_secret_key}"')`

---

## 1. Create the Meter (aggregation: sum)

The meter `event_name` MUST equal your `stripe_meter` config and the
`event_name` your client sends in meter events. The payload keys must match what
`report_meter_event` sends (`value`, `stripe_customer_id`).

```sh
curl -s https://api.stripe.com/v1/billing/meters -u "$RK:" \
  -d "display_name=<App> active users" \
  -d "event_name=<app>_active_user" \
  -d "default_aggregation[formula]=sum" \
  -d "customer_mapping[type]=by_id" \
  -d "customer_mapping[event_payload_key]=stripe_customer_id" \
  -d "value_settings[event_payload_key]=value"
# -> id mtr_…
```

## 2. Create the Product

```sh
curl -s https://api.stripe.com/v1/products -u "$RK:" \
  -d "name=<App> team" \
  -d "description=…"
# -> id prod_…
```

## 3. Create the metered Price (tied to the meter)

```sh
curl -s https://api.stripe.com/v1/prices -u "$RK:" \
  -d "product=$PROD" \
  -d "currency=gbp" \
  -d "unit_amount=300" \                 # minor units: £3.00
  -d "recurring[interval]=month" \
  -d "recurring[usage_type]=metered" \
  -d "recurring[meter]=$METER" \
  -d "nickname=<App> team - per active user"
# -> id price_…   (put this in the COMMITTED conf as stripe_price_id; it is not secret)
```

## 4. Create the Webhook endpoint and capture the signing secret

The endpoint URL must be the **publicly reachable** app for this environment
(live: `https://<app-domain>/stripe/webhook`). **Do not** point a *test* webhook
at the live app - test events would hit live and fail signature checks. The dev
host usually isn't public, so for dev either skip the webhook (the trial flow
writes its own state) or use the Stripe CLI `stripe listen --forward-to`.

Subscribe to exactly the events the `stripe_event` task handles:

```sh
curl -s https://api.stripe.com/v1/webhook_endpoints -u "$RK:" \
  -d "url=https://<app-domain>/stripe/webhook" \
  -d "enabled_events[]=customer.subscription.created" \
  -d "enabled_events[]=customer.subscription.updated" \
  -d "enabled_events[]=customer.subscription.deleted" \
  -d "enabled_events[]=invoice.paid" \
  -d "enabled_events[]=invoice.payment_failed" \
  -d "enabled_events[]=invoice.upcoming" \
  -d "enabled_events[]=customer.updated"
# response includes "secret": "whsec_…"  <-- capture this; it is shown ONCE
```

Write the secrets file **on the host for this environment** (never on dev for a
live key, never committed), `chmod 600`. Build the content with the key + whsec
and pipe over ssh so neither is printed:

```sh
printf '%s\n' \
"{" \
"    stripe_secret_key     => '$RK'," \
"    stripe_webhook_secret => '$WHSEC'," \
"}" | ssh PROD 'umask 077; cat > /path/conf/secrets.local.conf && chmod 600 /path/conf/secrets.local.conf'
```

Set `stripe_price_id` in the **committed** `conf/<mode>.conf` (it is not a
secret). Commit, deploy. The deploy's `git reset --hard` does NOT touch the
git-ignored secrets file.

## 5. Configure the Customer Portal (branding in copy + links)

The app opens the **default** portal configuration (it passes no config id), so
update the default. Visual branding (logo/colour) comes from account Branding
(step 6); the config controls headline, links, and which controls show.

```sh
# find the default config:
curl -s "https://api.stripe.com/v1/billing_portal/configurations?limit=10" -u "$RK:"
# update it:
curl -s -X POST "https://api.stripe.com/v1/billing_portal/configurations/$BPC" -u "$RK:" \
  --data-urlencode "business_profile[headline]=<App> - <tagline>" \
  --data-urlencode "business_profile[privacy_policy_url]=https://<app-domain>/privacy" \
  --data-urlencode "business_profile[terms_of_service_url]=https://<app-domain>/terms" \
  --data-urlencode "default_return_url=https://<app-domain>"
```

Sensible defaults that are usually already on: update card, invoice history,
cancel, update details. Leave **subscription plan-change OFF** for a single
plan.

## 6. Branding (dashboard - the restricted key cannot do this)

Account branding drives the look of **both** Checkout and the Portal. It needs
account-write + file upload, which the restricted key intentionally lacks, so
it is dashboard-only: **Settings -> Branding**:
- Brand colour (the app's primary hex), accent colour
- Icon (a square mark), Logo (a wordmark; leave blank to show the business name)

## 7. Account activation (live only)

Creating objects + the webhook works pre-activation, but Stripe will not
**charge** until the account is activated (business profile + bank details at
`dashboard.stripe.com/account/onboarding`). A no-card trial still starts before
activation - activation only governs the charge when the trial converts. The
restricted key can't read `charges_enabled` unless you add Account->Read to it;
the dashboard's "You're ready to go" is the signal.

When asked "how do you want to accept recurring payments?", choose **Pre-built
checkout form** (the app redirects to Stripe-hosted Checkout + uses the Portal).

---

## Verify the wiring

```sh
# 503 = no secret loaded; 400 = secret loaded, signature invalid (the healthy unsigned result)
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://<app-domain>/stripe/webhook -d x=1   # expect 400

# Prove the secret is the CORRECT one: sign a probe from the host where whsec lives.
ssh PROD bash -s <<'EOF'
WHSEC=$(perl -e 'my $c=do "/path/conf/secrets.local.conf"; print $c->{stripe_webhook_secret}')
T=$(date +%s)
BODY='{"id":"evt_probe","type":"customer.subscription.updated","data":{"object":{"id":"sub_x","customer":"cus_none","status":"active"}}}'
SIG=$(perl -MDigest::SHA=hmac_sha256_hex -e 'print hmac_sha256_hex($ARGV[0].".".$ARGV[1],$ARGV[2])' "$T" "$BODY" "$WHSEC")
curl -s -o /dev/null -w "signed -> %{http_code}\n" -X POST https://<app-domain>/stripe/webhook \
  -H "Stripe-Signature: t=$T,v1=$SIG" -H "Content-Type: application/json" --data-binary "$BODY"   # expect 200
EOF
```

A signed probe enqueues a real `stripe_event` job that records the synthetic
`evt_probe` in `stripe_events` (unmatched customer -> logged + recorded). Delete
it afterward if you mind the row: `DELETE FROM stripe_events WHERE event_id='evt_probe'`.

## Backfilling existing customers

If you change what the webhook records (e.g. you add card-on-file tracking after
trials already exist), the past events won't re-fire (and `event_seen` would
skip them anyway). Backfill directly from confirmed Stripe state, e.g.
`UPDATE accounts SET has_payment_method=true WHERE stripe_customer_id='cus_…'`
after verifying the card exists via the API.
