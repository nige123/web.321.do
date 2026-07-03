package L2D::Web::Controller::Accounts;

#------------------------------------------------------------------------------
# Public account page at /@:handle.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use L2D::Model::Accounts;

sub show ($c) {
    my $handle  = $c->stash('handle');
    my $account = L2D::Model::Accounts->new(db => $c->db)->get_by_handle($handle);

    return $c->reply->not_found unless $account;

    return $c->render(template => 'accounts/show', account => $account);
}

1;
