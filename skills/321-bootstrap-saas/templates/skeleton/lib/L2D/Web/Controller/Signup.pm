# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Web::Controller::Signup;

#------------------------------------------------------------------------------
# /signup - collect email + handle, create the user + personal account + owner
# membership, then hand off to the passcode flow to verify the email.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use L2D::Auth::Passcodes;
use L2D::Model::Users;
use L2D::Model::Accounts;

sub new_form ($c) {
    return $c->render(template => 'auth/signup',
        error => undef, email => '', handle => '');
}

sub create ($c) {
    my $email  = lc($c->param('email') // '');
    my $handle = $c->param('handle') // '';
    $email =~ s/\A\s+|\s+\z//g;

    unless ($email =~ /\A[^@\s]+\@[^@\s]+\z/) {
        return $c->render(template => 'auth/signup',
            error => 'Please enter a valid email address.',
            email => $email, handle => $handle);
    }

    my $users    = L2D::Model::Users->new(db => $c->db);
    my $accounts = L2D::Model::Accounts->new(db => $c->db);

    my $u = $users->find_or_create_by_email($email);
    my $r = $accounts->create_personal({ user_id => $u->{user_id}, handle => $handle });

    unless ($r->{ok}) {
        my $msg = $r->{error} eq 'one_personal_per_user'
                    ? 'You already have an account; sign in instead.'
                : $r->{error} eq 'handle_taken'
                    ? 'That handle is already taken - try another.'
                    : 'That handle isn\'t available - try another.';
        return $c->render(template => 'auth/signup',
            error => $msg, email => $email, handle => $handle);
    }

    my $issued = L2D::Auth::Passcodes->new(db => $c->db)->issue($email);
    $c->minion->enqueue(email_passcode => [ $issued->{email}, $issued->{code} ]);

    $c->session(signin_email => $issued->{email});
    $c->flash(notice => "Check $email for your sign-in code.");
    return $c->redirect_to('/signin/code');
}

1;
