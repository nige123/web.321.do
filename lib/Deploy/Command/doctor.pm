package Deploy::Command::doctor;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Probe SSL certs of every live host and report mismatches';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($_unused, $target) = $self->parse_target(@args);
    $target ||= 'live';
    $self->config->target($target);

    my @rows;
    for my $name (@{ $self->config->service_names }) {
        my $svc = $self->config->service($name);
        next unless $svc;
        next if $svc->{is_worker};
        my $host = $svc->{host} // 'localhost';
        next if $host eq 'localhost';

        my $probe = $self->nginx->probe_cert($host);
        push @rows, { name => $name, host => $host, probe => $probe };
    }

    my $bad = grep { !$_->{probe}{ok} } @rows;
    say "Checked " . scalar(@rows) . " host(s) on $target target  ("
        . ($bad ? "\e[31m$bad failing\e[0m" : "\e[32mall good\e[0m") . ")";
    say "";

    for my $row (@rows) {
        my $p = $row->{probe};
        if ($p->{ok}) {
            printf "  \e[32m[OK]\e[0m   %-30s %s\n", $row->{name}, $row->{host};
        } else {
            printf "  \e[31m[FAIL]\e[0m %-30s %s\n", $row->{name}, $row->{host};
            say   "         $p->{error}" if $p->{error};
            say   "         Fix: 321 go $row->{name} $target" unless $p->{error} && $p->{error} =~ /no TLS/;
        }
    }

    exit 1 if $bad;
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION doctor [target]

  Probes every non-localhost service host on the target (default: live)
  and reports any cert that doesn't match its hostname. Exit code is
  non-zero when any check fails — wire it into a cron if you want alerts.

  321 doctor             # check live
  321 doctor live        # explicit
  321 doctor dev         # also works for dev (mkcert)

=cut
