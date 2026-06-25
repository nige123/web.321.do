# 321-stripe skill template — port to <NS>::Web::Controller::Stripe ; see SKILL.md
package <NS>::Web::Controller::Stripe;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Stripe.pm
# Description:  Stripe webhook receiver. Verifies the signature over the raw
#               request body (never trust an unverified event), enqueues a
#               Minion stripe_event job, and acks 200 fast. All state changes
#               happen in the worker, not here.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use <NS>::Stripe::Webhook;

sub webhook ($c) {
    my $secret = $c->app->config('stripe_webhook_secret') // '';
    return $c->render(text => 'billing not enabled', status => 503)
        unless length $secret;

    my $body = $c->req->body;
    my $sig  = $c->req->headers->header('Stripe-Signature') // '';
    my ($ok, $event) = <NS>::Stripe::Webhook->verify($body, $sig, $secret, time);
    unless ($ok) {
        $c->app->log->warn("[stripe] webhook rejected: $event->{error}");
        return $c->render(text => 'bad signature', status => 400);
    }

    $c->minion->enqueue(stripe_event => [$event]);
    return $c->render(text => 'ok', status => 200);
}

1;
