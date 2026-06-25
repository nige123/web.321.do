# 321-stripe skill template — port to <NS>::Web ; see SKILL.md
#
# REFERENCE SNIPPET, NOT EXECUTABLE. These are the billing-related pieces to
# splice into your application class (the equivalent of <NS>::Web / Mojolicious
# app). Each block is labelled; lift it into the matching method of your app:
#   (a)(b) -> _setup_helpers
#   (c)    -> _setup_minion
#   (d)    -> package-level helper subs (top of the file, outside startup)
#   (e)    -> _setup_routes
#   (f)    -> _setup_database
#
# Generalise <NS>:: to your namespace and <app>_active_user to your meter name.

# ---- (d) package-level helper subs (top of the file, outside startup) -------

#------------------------------------------------------------------------------
# _trial_days_left - whole days from now until $trial_ends_at. Rounds up so the
#   final day reads "1 day", never 0; clamps at a minimum of 1 so an
#   expired-but-still-trialing account never shows a negative.
#------------------------------------------------------------------------------
sub _trial_days_left ($trial_ends_at) {
    return 1 unless defined $trial_ends_at && length $trial_ends_at;
    my $end = Mojo::Date->new(_to_rfc3339($trial_ends_at))->epoch;
    return 1 unless $end;
    my $secs = $end - time;
    return 1 if $secs <= 0;
    my $days = int($secs / 86400);
    $days++ if $secs % 86400;        # round up partial days
    return $days < 1 ? 1 : $days;
}

#------------------------------------------------------------------------------
# _to_rfc3339 - coax a Postgres TIMESTAMPTZ string (space separator, fractional
#   seconds, bare "+01" offset) into the RFC 3339 form Mojo::Date parses.
#   "2026-06-28 22:48:24.315315+01" -> "2026-06-28T22:48:24+01:00"
#------------------------------------------------------------------------------
sub _to_rfc3339 ($ts) {
    $ts =~ s/ /T/;                       # space -> T
    $ts =~ s/\.\d+//;                    # drop fractional seconds
    $ts =~ s/([+-]\d\d)$/$1:00/;         # +01 -> +01:00
    return $ts;
}


# ---- (c) _setup_minion : $build_service closure + the two Stripe tasks -------
# (place these alongside the other ->add_task calls inside _setup_minion)

    # --- Stripe billing -----------------------------------------------------
    my $build_service = sub ($job) {
        require <NS>::Billing::Service;
        require <NS>::Stripe::Client;
        return <NS>::Billing::Service->new(
            db         => $job->app->db,
            price_id   => $job->app->config('stripe_price_id')   // '',
            meter      => $job->app->config('stripe_meter')      // '<app>_active_user',
            trial_days => 30,
            client     => <NS>::Stripe::Client->new(
                log        => $job->app->log,
                ua         => $job->app->ua,
                secret_key => $job->app->config('stripe_secret_key') // '',
            ),
        );
    };

    # The only writer of billing state. Process-then-record: skip if already
    # seen, apply (idempotent), record last — so a mid-job failure reprocesses
    # safely on retry (spec §12).
    $self->minion->add_task(stripe_event => sub ($job, $event) {
        my $db      = $job->app->db;
        my $billing = <NS>::Model::Billing->new(db => $db);
        my $id      = $event->{id};
        my $type    = $event->{type} // '';
        return $job->fail('event missing id') unless defined $id && length $id;
        return $job->finish('skipped: already seen') if $billing->event_seen($id);

        my $obj = $event->{data}{object} // {};
        my $iso = sub ($epoch) {
            return undef unless $epoch;
            return Mojo::Date->new($epoch)->to_datetime;
        };

        # A NULL field below means "this event carries no such value" — the
        # UPDATE keeps the existing column (COALESCE in set_subscription).
        my $matched = 1;
        if ($type eq 'customer.subscription.created'
         || $type eq 'customer.subscription.updated') {
            $matched = $billing->apply_subscription_state($obj->{customer}, {
                status             => $obj->{status},
                subscription_id    => $obj->{id},
                current_period_end => $iso->($obj->{current_period_end}),
                trial_ends_at      => $iso->($obj->{trial_end}),
                # sticky on created AND updated: a sub-level default card turns
                # the flag on; its absence binds undef, which (with the sticky-OR
                # in set_subscription) PRESERVES a customer-level true rather than
                # wiping it. Card removal is handled by the past_due path.
                has_payment_method => ($obj->{default_payment_method} ? 'true' : undef),
            });
        }
        elsif ($type eq 'customer.subscription.deleted') {
            $matched = $billing->mark_canceled($obj->{customer});
        }
        elsif ($type eq 'customer.updated') {
            # data.object is the CUSTOMER here: its id IS the stripe_customer_id,
            # and the default card lives at invoice_settings.default_payment_method.
            # Catches a card set as the customer's default (e.g. via the Portal)
            # even when no sub-level default_payment_method event fires. Sticky-OR.
            my $has = $obj->{invoice_settings}{default_payment_method} ? 1 : 0;
            $matched = $billing->note_payment_method($obj->{id}, $has);
        }
        elsif ($type eq 'invoice.paid') {
            $matched = $billing->apply_subscription_state($obj->{customer}, {
                status => 'active', subscription_id => undef,
                current_period_end => $iso->($obj->{period_end}), trial_ends_at => undef });
        }
        elsif ($type eq 'invoice.payment_failed') {
            $matched = $billing->apply_subscription_state($obj->{customer}, {
                status => 'past_due', subscription_id => undef,
                current_period_end => $iso->($obj->{period_end}), trial_ends_at => undef });
        }
        elsif ($type eq 'invoice.upcoming') {
            my $acct = $billing->account_by_customer($obj->{customer});
            $matched = $acct;
            if ($acct) {
                $job->app->minion->enqueue(stripe_report_usage => [
                    $acct->{account_id},
                    $iso->($obj->{period_start}),
                    $iso->($obj->{period_end}),
                ]);
            }
        }

        # Unmatched customers are warned about (spec §12) but still recorded,
        # so Stripe stops retrying an event we can never apply. The finish
        # note makes the mismatch visible on the job itself.
        unless ($matched) {
            my $customer = $obj->{customer} // '(none)';
            $job->app->log->warn(
                "[stripe] event $id ($type): no account matches customer $customer");
            $billing->record_event($id, $type);
            return $job->finish("unmatched customer $customer");
        }

        $billing->record_event($id, $type);
        return;
    });

    $self->minion->add_task(stripe_report_usage => sub ($job, $account_id, $from, $to) {
        $build_service->($job)->report_usage($account_id, $from, $to);
    });


# ---- (b) _setup_helpers : billing_banner helper -----------------------------

    # The trial-nudge banner for the team page currently being viewed. Returns a
    # hashref { message, action_label } when an owner/admin is looking at one of
    # their team's pages while it is `trialing` or `past_due` (and they have not
    # dismissed it this session), else undef. Memoized like passkey_nudge.
    # Dismissal is session-scoped on purpose: it reappears next session as the
    # trial shortens, which is cheaper and more appropriate than a DB flag.
    $self->helper(billing_banner => sub ($c) {
        return $c->stash->{'favsix.billing_banner'}
            if exists $c->stash->{'favsix.billing_banner'};

        my $none = sub { return $c->stash->{'favsix.billing_banner'} = undef };

        return $none->() if $c->session->{'billing_nudge_dismissed'};

        my $handle = $c->stash('handle');
        return $none->() unless defined $handle && length $handle;

        my $user = $c->current_user or return $none->();

        my $accounts = <NS>::Model::Accounts->new(db => $c->db);
        my $account  = $accounts->get_by_handle($handle);
        return $none->() unless $account && ($account->{kind} // '') eq 'team';

        my $status = $account->{billing_status} // '';
        return $none->() unless $status eq 'trialing' || $status eq 'past_due';

        my $role = $accounts->member_role($account->{account_id}, $user->{user_id});
        return $none->() unless $role && <NS>::Auth::Roles::can_administer_team($role);

        my $banner;
        if ($status eq 'past_due') {
            $banner = {
                message      => 'Payment failed - update your card to keep private FavSixes.',
                action_label => 'Update payment',
                handle       => $account->{handle},
            };
        }
        else {
            # trialing: if a card is already on file, there is nothing to nag
            # about - the card will simply be charged when the trial ends.
            return $none->() if $account->{has_payment_method};
            my $days = _trial_days_left($account->{trial_ends_at});
            my $unit = $days == 1 ? 'day' : 'days';
            $banner = {
                message      => "Your team trial ends in $days $unit - add a card.",
                action_label => 'Manage billing',
                handle       => $account->{handle},
            };
        }
        return $c->stash->{'favsix.billing_banner'} = $banner;
    });


# ---- (a) _setup_helpers : billing_service helper ----------------------------

    $self->helper(billing_service => sub ($c_or_app) {
        my $app = $c_or_app->can('app') ? $c_or_app->app : $c_or_app;
        require <NS>::Billing::Service;
        require <NS>::Stripe::Client;
        return <NS>::Billing::Service->new(
            db       => $app->db,
            price_id => $app->config('stripe_price_id') // '',
            meter    => $app->config('stripe_meter')    // '<app>_active_user',
            client   => <NS>::Stripe::Client->new(
                log        => $app->log,
                ua         => $app->ua,
                secret_key => $app->config('stripe_secret_key') // '',
            ),
        );
    });


# ---- (e) _setup_routes : billing-related routes -----------------------------

    # public webhook receiver (no auth — Stripe signs the body, we verify it)
    $r->post('/stripe/webhook')->to('Stripe#webhook');

    # billing — start the no-card trial, open the Stripe Customer Portal
    $r->post('/@:handle/billing/trial')->to('Billing#start_trial');
    $r->post('/@:handle/billing/portal')->to('Billing#portal');
    # dismiss the trial-nudge banner (session-scoped, no DB flag)
    $r->post('/billing/nudge/dismiss')->to('Billing#dismiss_nudge');


# ---- (f) _setup_database : auto_migrate so billing columns/tables apply ------
# (the migration file must already contain the billing pieces — see migration.sql)

    my $pg = Mojo::Pg->new($self->config('db_connect_string'));

    $pg->migrations
       ->name('<app>')
       ->from_file($self->home->rel_file('db/migration.sql'));

    $pg->auto_migrate(1);
