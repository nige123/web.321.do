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

    # On live, presence of a cert file is not enough - probe what's served so
    # an expired / expiring / wrong-host cert is caught. dev (mkcert) trusts
    # the file.
    my $probe = ($target ne 'dev' && $status->{ssl}) ? $self->nginx->probe_cert($host) : undef;
    say "  cert:    " . ($probe ? _cert_summary($probe) : ($status->{ssl} ? 'present' : 'none'));
    my $need_cert = $force || $self->_needs_cert($target, $status, $probe);

    if (!$need_cert && $status->{config_exists} && $status->{enabled} && $status->{ssl}) {
        say "";
        say "  \e[32mNginx fully configured, cert valid.\e[0m  (use --force to regenerate)";
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

    # Acquire when the cert is missing / expired / expiring / wrong-host, when
    # aliases were added (acquire_cert is idempotent and expands the SAN list),
    # or whenever --force is given (the operator explicitly asked).
    if ($need_cert || @aliases) {
        my $provider = $self->nginx->cert_provider->pick($target);
        my $verb = ($status->{ssl} && $target ne 'dev') ? 'Renewing' : 'Requesting';
        say "  $verb SSL certificate via $provider...";
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
                say "  [FAIL] certbot failed:";
                say "  $_" for grep { length } split /\n/, ($cert->{output} // '');
                say "";
                say "  (if DNS for $host isn't pointed at the server yet, fix that and re-run:";
                say "    321 nginx $name $target)";
            }
        }
    }
}

# One-line human summary of a probe_cert result for the status block.
sub _cert_summary ($probe) {
    return "\e[31munreachable\e[0m ($probe->{error})" unless $probe->{reachable};
    return "\e[31mexpired\e[0m ($probe->{error})"     if $probe->{expired};
    return "\e[31mwrong host\e[0m ($probe->{error})"  unless $probe->{host_match} // 1;
    return "\e[33mexpiring\e[0m ($probe->{days_remaining} days left)" if $probe->{expiring};
    my $days = $probe->{days_remaining};
    return "\e[32mvalid\e[0m" . (defined $days ? " ($days days left)" : "");
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION nginx <service> [target] [--force]

  Check and set up nginx + SSL for a service.

  321 nginx 123.api               # check/setup locally (mkcert)
  321 nginx 123.api live          # check/setup on production (certbot)
  321 nginx zorda.api live --force  # regenerate even if already configured

=cut
