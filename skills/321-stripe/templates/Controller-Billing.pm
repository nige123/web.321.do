# 321-stripe skill template — port to <NS>::Web::Controller::Billing ; see SKILL.md
package <NS>::Web::Controller::Billing;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Billing.pm
# Description:  Customer-facing billing - start the no-card trial and open the
#               Stripe Customer Portal. Owner/admin only. Stripe work is done by
#               the billing_service helper (a testable seam).
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use <NS>::Model::Accounts;
use <NS>::Auth::Roles qw(can_administer_team);

#------------------------------------------------------------------------------
# _team_admin - the team $account if the current user is owner/admin at :handle,
#   else undef (caller renders 403).
#------------------------------------------------------------------------------
sub _team_admin ($c) {
    my $accounts = <NS>::Model::Accounts->new(db => $c->db);
    my $account  = $accounts->get_by_handle($c->param('handle'));
    return undef unless $account && ($account->{kind} // '') eq 'team';
    my $user = $c->current_user or return undef;
    my $role = $accounts->member_role($account->{account_id}, $user->{user_id});
    return undef unless $role && can_administer_team($role);
    return $account;
}

#------------------------------------------------------------------------------
# start_trial - POST /@:handle/billing/trial
#------------------------------------------------------------------------------
sub start_trial ($c) {
    my $account = _team_admin($c)
        or return $c->render(text => 'forbidden', status => 403);

    my $res = eval { $c->billing_service->begin_trial($account) };
    my $msg;
    if (!$res) {
        $msg = 'Could not start the trial - please try again.';
    } elsif ($res->{ok}) {
        $msg = 'Your 30-day free trial has started.';
    } elsif (($res->{reason} // '') eq 'trial_used') {
        $msg = 'This team has already used its free trial.';
    } else {
        $msg = "Billing isn't configured yet - try again soon.";
    }
    $c->flash(notice => $msg);
    return $c->redirect_to("/\@$account->{handle}/settings#billing");
}

#------------------------------------------------------------------------------
# portal - POST /@:handle/billing/portal
#------------------------------------------------------------------------------
sub portal ($c) {
    my $account = _team_admin($c)
        or return $c->render(text => 'forbidden', status => 403);

    unless ($account->{stripe_customer_id}) {
        $c->flash(notice => 'Start your free trial first.');
        return $c->redirect_to("/\@$account->{handle}/settings#billing");
    }

    my $return_url = ($c->config('stripe_portal_return_url') // $c->config('base_url') // '')
                   . "/\@$account->{handle}/settings#billing";
    my $session = eval {
        $c->billing_service->client->create_billing_portal_session(
            $account->{stripe_customer_id}, $return_url);
    };
    unless ($session && $session->{url}) {
        $c->flash(notice => 'Could not open billing right now - try again.');
        return $c->redirect_to("/\@$account->{handle}/settings#billing");
    }
    return $c->redirect_to($session->{url});
}

#------------------------------------------------------------------------------
# _safe_return - sanitise a return path so we only redirect within this app
#   (must be path-absolute, no protocol-relative URLs, no header injection).
#   Mirrors <NS>::Web::Controller::Auth::_safe_next; replicated locally to avoid
#   a cross-package call.
#------------------------------------------------------------------------------
sub _safe_return ($path) {
    return undef unless defined $path && length $path;
    return undef unless $path =~ m{\A/};   # must be path-absolute
    return undef if $path =~ m{\A//};      # block protocol-relative
    return undef if $path =~ m{[\r\n]};    # block header injection
    return $path;
}

#------------------------------------------------------------------------------
# dismiss_nudge - POST /billing/nudge/dismiss
#   "Not now" on the trial banner. Session-scoped (no DB flag) so the banner
#   reappears in a new session as the trial shortens. Redirects back to the
#   page the banner was shown on (sanitised), else to '/'.
#------------------------------------------------------------------------------
sub dismiss_nudge ($c) {
    $c->session->{'billing_nudge_dismissed'} = 1;
    my $back = _safe_return($c->param('return'));
    return $c->redirect_to($back // '/');
}

1;
