package Deploy::Command::nginx;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Check or set up nginx + SSL for a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my $force = 0;
    @args = grep { $_ eq '--force' ? do { $force = 1; 0 } : 1 } @args;

    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    $self->config->target($target);
    my $transport = $self->transport_for($name, $target);

    my $svc     = $self->config->service($name);
    my $host    = $svc->{host} // 'localhost';
    my $port    = $svc->{port};
    my @aliases = @{ $svc->{aliases} // [] };

    unless ($host ne 'localhost' && $port) {
        say "  No host/port configured for $name ($target)";
        return;
    }

    $self->nginx->transport($transport);

    my $status = $self->nginx->status($name);
    say "  $name ($target)";
    say "  host:    $host";
    say "  aliases: @aliases" if @aliases;
    say "  port:    $port";
    say "  config:  " . ($status->{config_exists} ? "\e[32mexists\e[0m" : "\e[31mmissing\e[0m");
    say "  enabled: " . ($status->{enabled} ? "\e[32myes\e[0m" : "\e[31mno\e[0m");
    say "  ssl:     " . ($status->{ssl} ? "\e[32m$status->{provider}\e[0m" : "\e[31mnone\e[0m");

    if (!$force && $status->{config_exists} && $status->{enabled} && $status->{ssl}) {
        say "";
        say "  \e[32mNginx fully configured.\e[0m  (use --force to regenerate)";
        return;
    }

    say "";
    say $force ? "  Regenerating..." : "  Setting up...";

    # Generate + enable + test + reload
    my $result = $self->nginx->setup($name);
    for my $step (@{ $result->{steps} // [] }) {
        my $s = $self->step_ok($step);
        printf "  [%s] %s\n", ($s ? 'OK' : 'FAIL'), $step->{step};
        unless ($s) {
            say "";
            say "  Next: check nginx config:";
            say "    sudo nginx -t";
            return;
        }
    }

    # SSL cert. With aliases configured, always ask - acquire_cert is
    # idempotent and expands an existing cert that doesn't cover them yet.
    if (!$status->{ssl} || @aliases) {
        my $provider = $self->nginx->cert_provider->pick($target);
        say "  Requesting SSL certificate via $provider...";
        my $cert = $self->nginx->acquire_cert($name);
        if ($cert->{status} eq 'ok') {
            say "  [OK] SSL cert ready ($provider)";
            # Regenerate config with SSL and reload
            $self->nginx->generate($name);
            $self->nginx->reload;
            say "  [OK] nginx reloaded with SSL";
        } else {
            if ($provider eq 'mkcert') {
                say "  [FAIL] mkcert failed";
                say "";
                say "  Next: install mkcert:";
                say "    sudo apt install -y libnss3-tools mkcert";
                say "    mkcert -install";
                say "  Then re-run: 321 nginx $name" . $self->target_flag($target);
            } else {
                say "  [SKIP] certbot failed - DNS may not be pointed yet";
                say "";
                say "  Next: point DNS for $host to the server, then:";
                say "    321 nginx $name $target";
            }
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION nginx <service> [target] [--force]

  Check and set up nginx + SSL for a service.

  321 nginx 123.api               # check/setup locally (mkcert)
  321 nginx 123.api live          # check/setup on production (certbot)
  321 nginx zorda.api live --force  # regenerate even if already configured

=cut
