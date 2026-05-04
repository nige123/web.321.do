package Deploy::Command::go;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Local;
use Deploy::Command::install;

has description => 'Deploy a service: install if new, otherwise hot-restart';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    $self->config->target($target);

    my $svc = $self->config->service($name);

    # Run tests before deploying to live
    if ($target ne 'dev' && $svc->{test}) {
        say "Running tests before deploy...";
        say "";
        my $local = Deploy::Local->new;
        my $r = $local->stream("cd $svc->{repo} && $svc->{test}");
        unless ($r->{ok}) {
            say "";
            say "  \e[31mTests failed - deploy aborted\e[0m";
            return;
        }
        say "";
        say "  \e[32mTests passed\e[0m";
        say "";
    }

    my $transport = $self->transport_for($name, $target);

    # First-time bring-up vs hot-restart: install if the repo OR the ubic
    # service file is missing. A partial install (repo cloned but ubic file
    # gone) re-triggers install rather than failing in deploy.
    my ($group, $svc_short) = split /\./, $name, 2;
    my $check = $transport->run(
        "test -d $svc->{repo}/.git && test -e ~/ubic/service/$group/$svc_short && echo OK"
    );
    my $needs_install = ($check->{output} // '') !~ /OK/;

    if ($needs_install) {
        my $install = Deploy::Command::install->new(app => $self->app);
        $install->run($name, $target);
        return;
    }

    my $svc_mgr = $self->svc_mgr;
    $svc_mgr->transport($transport);

    say "3... 2... 1... deploying $name ($target)";
    my $skip_git = ($target eq 'dev') ? 1 : 0;
    my $r = $svc_mgr->deploy($name, skip_git => $skip_git);
    $self->print_steps($r);
    say "  $r->{message}" if $r->{message};

    $self->_check_cert_health($name, $target, $transport);
}

sub _check_cert_health ($self, $name, $target, $transport) {
    my $svc = $self->config->service($name);
    my $host = $svc->{host} // 'localhost';
    return if $host eq 'localhost' || $target eq 'dev';

    my $probe = $self->nginx->probe_cert($host);
    return if $probe->{ok};

    say "";
    say "  \e[33mSSL: $probe->{error}\e[0m" if $probe->{error};
    say "  Setting up nginx + SSL on $target...";

    $self->nginx->transport($transport);
    my $setup = $self->nginx->setup($name);
    $self->print_steps({ data => $setup });

    my $cert = $self->nginx->acquire_cert($name);
    unless ($cert->{status} eq 'ok') {
        say "  [FAIL] cert acquisition";
        say "  $cert->{output}" if $cert->{output};
        return;
    }

    say "  [OK] cert acquired ($cert->{provider})";
    $self->nginx->generate($name);
    $self->nginx->reload;
    say "  [OK] nginx reloaded with SSL";

    my $reprobe = $self->nginx->probe_cert($host);
    say $reprobe->{ok}
      ? "  \e[32mhttps://$host serves the right cert\e[0m"
      : "  \e[31mstill wrong cert: $reprobe->{error}\e[0m";
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION go [service] [target]

  First run on a target installs (clone, deps, ubic, nginx, SSL, start).
  Later runs hot-restart via hypnotoad (git pull, cpanm, ubic restart).

  321 go              # deploy current repo to dev
  321 go live         # deploy current repo to live
  321 go zorda.web    # deploy zorda.web to dev

=cut
