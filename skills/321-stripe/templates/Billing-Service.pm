# 321-stripe skill template — port to <NS>::Billing::Service ; see SKILL.md
package <NS>::Billing::Service;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Service.pm
# Description:  Orchestrates billing actions across the Stripe client and the
#               DB models. begin_trial starts the once-per-account 30-day trial
#               (create customer + subscription, then persist via the Billing
#               model). report_usage computes the active-member count from our
#               own data and reports it once per period to the Stripe Meter.
#               All Stripe calls are blocking and may die on transport error;
#               synchronous callers (controllers) must wrap begin_trial.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::Date;
use <NS>::Model::Billing;
use <NS>::Model::Activity;

has 'db';
has 'client';                       # <NS>::Stripe::Client
has price_id   => '';
has meter      => '<app>_active_user';
has trial_days => 30;

sub _billing  ($self) { <NS>::Model::Billing->new(db => $self->db) }
sub _activity ($self) { <NS>::Model::Activity->new(db => $self->db) }

#------------------------------------------------------------------------------
# begin_trial - start the once-per-account trial. Returns {ok=>1} or
#   {ok=>0, reason=>...}. No-op (no Stripe calls) when declined.
#------------------------------------------------------------------------------
sub begin_trial ($self, $account) {
    return { ok => 0, reason => 'billing_disabled' } unless $self->client->enabled;
    return { ok => 0, reason => 'trial_used' }
        if $account->{trial_ends_at} || $account->{stripe_subscription_id};

    my $cus = $self->client->create_customer($account);
    my $sub = $self->client->create_subscription(
        $cus->{id}, $self->price_id, $self->trial_days);

    my $trial_ends_at = Mojo::Date->new(time + $self->trial_days * 86400)->to_datetime;
    $self->_billing->start_trial(
        $account->{account_id}, $cus->{id}, $sub->{id}, $trial_ends_at);
    return { ok => 1, customer => $cus->{id}, subscription => $sub->{id} };
}

#------------------------------------------------------------------------------
# report_usage - report the account's active-member count for [$from,$to) to
#   the Stripe Meter, once per period (idempotency key "<account>:<from>").
#   Returns the reported count; skips the Stripe call when it's zero.
#------------------------------------------------------------------------------
sub report_usage ($self, $account_id, $from, $to) {
    my $account = $self->_billing->get($account_id);
    return 0 unless $account && $account->{stripe_customer_id};
    my $count = $self->_activity->active_count($account_id, $from, $to);
    return 0 if $count == 0;
    $self->client->report_meter_event(
        $self->meter, $account->{stripe_customer_id}, $count, "$account_id:$from");
    return $count;
}

1;
