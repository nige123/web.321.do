# 321-stripe skill template — port to <NS>::Stripe::Client ; see SKILL.md
package <NS>::Stripe::Client;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Client.pm
# Description:  Thin blocking Stripe REST client over Mojo::UserAgent, in the
#               same shape as <NS>::Email::Sender: inert when no secret key is
#               configured (dev/test), so the suite never touches the network.
#               A request_handler seam lets tests inject a fake responder.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Mojo::UserAgent;

has 'log';
has secret_key   => '';
has base_url     => 'https://api.stripe.com/v1';
has ua           => sub { Mojo::UserAgent->new->connect_timeout(5)->request_timeout(20) };
# Test seam: a coderef ($method, $path, $params, $idempotency_key) -> ($ok, $data).
has request_handler => undef;

sub enabled ($self) { return length $self->secret_key ? 1 : 0 }

#------------------------------------------------------------------------------
# create_customer - returns { id => 'cus_…' } or the not-enabled marker
#------------------------------------------------------------------------------
sub create_customer ($self, $account) {
    return { enabled => 0 } unless $self->enabled;
    my ($ok, $data) = $self->_request(POST => '/customers', {
        'name'                 => ($account->{handle} // ''),
        'metadata[account_id]' => $account->{account_id},
    }, "customer-$account->{account_id}");
    die "Stripe create_customer failed\n" unless $ok;
    return { enabled => 1, id => $data->{id} };
}

#------------------------------------------------------------------------------
# create_subscription - trialing subscription, no payment method required
#------------------------------------------------------------------------------
sub create_subscription ($self, $customer, $price, $trial_days) {
    return { enabled => 0 } unless $self->enabled;
    my ($ok, $data) = $self->_request(POST => '/subscriptions', {
        'customer'             => $customer,
        'items[0][price]'      => $price,
        'trial_period_days'    => $trial_days,
        'trial_settings[end_behavior][missing_payment_method]' => 'cancel',
        'payment_behavior'     => 'default_incomplete',
    }, undef);
    die "Stripe create_subscription failed\n" unless $ok;
    return { enabled => 1, id => $data->{id}, status => $data->{status} };
}

#------------------------------------------------------------------------------
# create_checkout_session - hosted card capture / subscription
#   %$opts: customer, price, success_url, cancel_url
#------------------------------------------------------------------------------
sub create_checkout_session ($self, $opts) {
    return { enabled => 0 } unless $self->enabled;
    my ($ok, $data) = $self->_request(POST => '/checkout/sessions', {
        'mode'                  => 'subscription',
        'customer'              => $opts->{customer},
        # Metered price: Stripe rejects an explicit quantity, so omit it.
        'line_items[0][price]'  => $opts->{price},
        'success_url'           => $opts->{success_url},
        'cancel_url'            => $opts->{cancel_url},
    }, undef);
    die "Stripe create_checkout_session failed\n" unless $ok;
    return { enabled => 1, url => $data->{url}, id => $data->{id} };
}

#------------------------------------------------------------------------------
# create_billing_portal_session - self-service management
#------------------------------------------------------------------------------
sub create_billing_portal_session ($self, $customer, $return_url) {
    return { enabled => 0 } unless $self->enabled;
    my ($ok, $data) = $self->_request(POST => '/billing_portal/sessions', {
        'customer'   => $customer,
        'return_url' => $return_url,
    }, undef);
    die "Stripe create_billing_portal_session failed\n" unless $ok;
    return { enabled => 1, url => $data->{url} };
}

#------------------------------------------------------------------------------
# report_meter_event - report one usage value; idempotent per key
#   Returns 1 on success, dies on hard failure (so Minion records + retries).
#------------------------------------------------------------------------------
sub report_meter_event ($self, $event_name, $customer, $value, $idempotency_key) {
    return 0 unless $self->enabled;
    my ($ok) = $self->_request(POST => '/billing/meter_events', {
        'event_name'                  => $event_name,
        'payload[value]'              => $value,
        'payload[stripe_customer_id]' => $customer,
    }, $idempotency_key);
    die "Stripe report_meter_event failed\n" unless $ok;
    return 1;
}

#------------------------------------------------------------------------------
# retrieve_subscription - for reconciliation
#------------------------------------------------------------------------------
sub retrieve_subscription ($self, $subscription_id) {
    return { enabled => 0 } unless $self->enabled;
    my ($ok, $data) = $self->_request(GET => "/subscriptions/$subscription_id", {}, undef);
    die "Stripe retrieve_subscription failed\n" unless $ok;
    return { enabled => 1, %$data };
}

#------------------------------------------------------------------------------
# _request - POST/GET to Stripe; delegates to request_handler when set
#------------------------------------------------------------------------------
sub _request ($self, $method, $path, $params, $idempotency_key = undef) {
    if (my $h = $self->request_handler) {
        return $h->($method, $path, $params, $idempotency_key);
    }
    my %headers = (Authorization => 'Bearer ' . $self->secret_key);
    $headers{'Idempotency-Key'} = $idempotency_key if defined $idempotency_key;
    my $url = $self->base_url . $path;
    my $tx  = $method eq 'GET'
        ? $self->ua->get($url => \%headers => form => $params)
        : $self->ua->post($url => \%headers => form => $params);
    my $res = $tx->result;
    if ($res && $res->is_success) {
        return (1, $res->json);
    }
    my $msg = ($res && eval { $res->json->{error}{message} })
            || ($res && $res->message) || 'request failed';
    $self->log->error("[stripe] $method $path failed: $msg") if $self->log;
    return (0, { error => $msg });
}

1;
