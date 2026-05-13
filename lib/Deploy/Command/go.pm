package Deploy::Command::go;

use Mojo::Base 'Deploy::Command', -signatures;
use Deploy::Local;
use Deploy::Command::install;
use Deploy::Hosts;

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

    $self->_ensure_serving($name, $target, $transport);
}

# A plain `321 go` should leave the service actually reachable — not just the
# ubic process running. So after the deploy: on dev make sure the hostname
# resolves; everywhere make sure the nginx vhost exists, is enabled, and has a
# cert; on live make sure that cert actually matches the host. Whatever's
# missing gets set up here.
sub _ensure_serving ($self, $name, $target, $transport) {
    my $svc  = $self->config->service($name);
    my $host = $svc->{host} // 'localhost';
    my $port = $svc->{port};
    return if $host eq 'localhost' || !$port;

    # On dev the vhost is useless unless the hostname resolves to us.
    $self->_ensure_dev_host($host) if $target eq 'dev';

    $self->nginx->transport($transport);
    my $st = $self->nginx->status($name) // {};

    if ($st->{config_exists} && $st->{enabled} && $st->{ssl}) {
        # Fully wired. On live, still confirm the cert matches the host
        # (catches a stale cert from a previous hostname); dev mkcert is fine.
        return if $target eq 'dev';
        my $probe = $self->nginx->probe_cert($host);
        return if $probe->{ok};
        say "";
        say "  \e[33mSSL: $probe->{error}\e[0m" if $probe->{error};
        say "  Repairing nginx + SSL for $host...";
    }
    else {
        my @missing;
        push @missing, 'config'  unless $st->{config_exists};
        push @missing, 'enabled' unless $st->{enabled};
        push @missing, 'SSL'     unless $st->{ssl};
        say "";
        say "  Nginx not fully configured for $host (missing: @{[join ', ', @missing]}) — setting up...";
    }

    my $setup = $self->nginx->setup($name);
    for my $step (@{ $setup->{steps} // [] }) {
        my $ok = $self->step_ok($step);
        printf "  [%s] %s\n", ($ok ? 'OK' : 'FAIL'), $step->{step};
        next if $ok;
        say "  $step->{output}" if $step->{output};
        say "  Next: check nginx config:  sudo nginx -t";
        return;
    }

    my $provider = $self->nginx->cert_provider->pick($target);
    unless ($st->{ssl}) {
        say "  Requesting SSL certificate via $provider...";
        my $cert = $self->nginx->acquire_cert($name);
        if ($cert->{status} eq 'ok') {
            say "  [OK] SSL ($provider)";
            $self->nginx->generate($name);   # re-render now the cert exists
            $self->nginx->reload;
            say "  [OK] nginx reloaded with SSL";
        }
        elsif ($provider eq 'mkcert') {
            say "  [SKIP] mkcert failed — install it, then re-run 321 go $name:";
            say "    sudo apt install -y libnss3-tools mkcert && mkcert -install";
            return;
        }
        else {
            say "  [SKIP] certbot failed — point DNS for $host at the server, then:";
            say "    321 nginx $name $target";
            return;
        }
    }

    return if $target eq 'dev';
    my $reprobe = $self->nginx->probe_cert($host);
    say $reprobe->{ok}
      ? "  \e[32mhttps://$host serves the right cert\e[0m"
      : "  \e[31mstill wrong cert: $reprobe->{error}\e[0m";
}

# Make sure $host is in the /etc/hosts managed block. Rewrites the whole block
# from every dev manifest (self-healing) — needs sudo, so only does the write
# when something's actually missing.
sub _ensure_dev_host ($self, $host) {
    my $hosts = Deploy::Hosts->new;
    return if grep { $_ eq $host } @{ $hosts->read };
    my $changed = eval { $hosts->sync($self->config->dev_hostnames) };
    if (my $err = $@) {
        chomp $err;
        say "  \e[33m/etc/hosts: couldn't add $host ($err)\e[0m";
        say "  Add it yourself:  echo '127.0.0.1  $host' | sudo tee -a /etc/hosts";
        return;
    }
    say "  [OK] /etc/hosts updated ($host)" if $changed;
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
