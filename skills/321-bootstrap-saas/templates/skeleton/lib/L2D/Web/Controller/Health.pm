# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Web::Controller::Health;

#------------------------------------------------------------------------------
# Health check endpoint for the 321 deploy tool (321.yml `health: /health`).
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub check ($c) {
    return $c->render(text => 'ok');
}

1;
