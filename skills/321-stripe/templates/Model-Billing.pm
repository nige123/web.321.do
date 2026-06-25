# 321-stripe skill template — port to <NS>::Model::Billing ; see SKILL.md
package <NS>::Model::Billing;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Billing.pm
# Description:  Billing state for team accounts. The single authority for
#               entitlement (whether private FavSixes are unlocked) and the
#               only writer of billing columns — driven by verified webhooks.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

has 'db';

my %ENTITLED = map { $_ => 1 } qw(trialing active past_due);

#------------------------------------------------------------------------------
# is_entitled - may this account have unlocked private FavSixes?
#------------------------------------------------------------------------------
sub is_entitled ($self, $account) {
    return $ENTITLED{ $account->{billing_status} // '' } ? 1 : 0;
}

#------------------------------------------------------------------------------
# gate_private - may this account use/keep private FavSixes? Personal accounts
#   always may (free creator tier); team accounts must be entitled. Requires the
#   account hash to carry both 'kind' and 'billing_status'.
#------------------------------------------------------------------------------
sub gate_private ($self, $account) {
    return 1 if ($account->{kind} // '') ne 'team';
    return $self->is_entitled($account);
}

sub get ($self, $account_id) {
    return $self->db->query('billing/get_account',
        { account_id => $account_id })->hash;
}

#------------------------------------------------------------------------------
# start_trial - begin the once-per-account trial (status=trialing)
#------------------------------------------------------------------------------
sub start_trial ($self, $account_id, $customer_id, $subscription_id, $trial_ends_at) {
    return $self->db->query('billing/start_trial', {
        account_id      => $account_id,
        customer_id     => $customer_id,
        subscription_id => $subscription_id,
        trial_ends_at   => $trial_ends_at,
    })->hash;
}

#------------------------------------------------------------------------------
# apply_subscription_state - mirror a Stripe subscription onto the account
#------------------------------------------------------------------------------
sub apply_subscription_state ($self, $customer_id, $state) {
    return $self->db->query('billing/set_subscription', {
        customer_id        => $customer_id,
        billing_status     => $state->{status},
        subscription_id    => $state->{subscription_id},
        current_period_end => $state->{current_period_end},
        trial_ends_at      => $state->{trial_ends_at},
        has_payment_method => $state->{has_payment_method},
    })->hash;
}

#------------------------------------------------------------------------------
# note_payment_method - record the customer-level default-card signal (from a
#   customer.updated webhook). Sticky-OR: $has true sets has_payment_method on;
#   a falsey $has OR-s in false, which preserves any existing true (a non-card
#   customer.updated never turns it off). Returns the updated row (truthy) when
#   a matching account exists, undef when none does.
#------------------------------------------------------------------------------
sub note_payment_method ($self, $customer_id, $has) {
    return $self->db->query('billing/set_payment_method', {
        customer_id => $customer_id,
        has         => $has ? 'true' : 'false',
    })->hash;
}

sub mark_canceled ($self, $customer_id) {
    return $self->db->query('billing/set_status', {
        customer_id    => $customer_id,
        billing_status => 'canceled',
    })->hash;
}

#------------------------------------------------------------------------------
# record_event - idempotency guard; true the first time, false on replay
#------------------------------------------------------------------------------
sub record_event ($self, $event_id, $type) {
    my $row = $self->db->query('billing/record_event',
        { event_id => $event_id, type => $type })->hash;
    return $row ? 1 : 0;
}

#------------------------------------------------------------------------------
# event_seen - has this webhook event already been processed?
#------------------------------------------------------------------------------
sub event_seen ($self, $event_id) {
    return $self->db->query('billing/event_seen',
        { event_id => $event_id })->rows ? 1 : 0;
}

#------------------------------------------------------------------------------
# account_by_customer - the account row for a Stripe customer id (or undef)
#------------------------------------------------------------------------------
sub account_by_customer ($self, $customer_id) {
    return $self->db->query('billing/account_by_customer',
        { customer_id => $customer_id })->hash;
}

1;
