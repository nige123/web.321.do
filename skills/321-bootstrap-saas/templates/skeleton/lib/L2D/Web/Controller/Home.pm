# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Web::Controller::Home;

#------------------------------------------------------------------------------
# Public landing page. A signed-in visitor is sent to their account.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use L2D::Model::Accounts;

sub landing ($c) {

    if (my $user = $c->current_user) {
        my $personal = L2D::Model::Accounts->new(db => $c->db)
            ->personal_for_user($user->{user_id});
        return $c->redirect_to("/\@$personal->{handle}") if $personal;
    }

    return $c->render(template => 'home/landing');
}

1;
