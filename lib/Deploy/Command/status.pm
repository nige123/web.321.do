package Deploy::Command::status;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Show service status';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    $self->config->target($target);

    my @names = $svc_input
        ? ($self->resolve_service($svc_input))
        : @{ $self->config->service_names };

    for my $name (@names) {
        my $svc = $self->config->service($name);
        my $transport = $self->transport_for($name, $target);
        my $r = $transport->run("ubic status $name");
        my $ubic_status = $r->{output} // '';
        chomp $ubic_status;
        $ubic_status =~ s/^.*?\t//;  # strip "service.name\t" prefix from ubic output
        $ubic_status =~ s/^\Q$name\E\s+//;  # fallback: strip by name if no tab

        my $port = $svc->{port} // '?';
        my $host = $svc->{host} // 'localhost';
        my $url  = $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";

        my $running = $ubic_status =~ /running/;
        my $color_status = $running
            ? "\e[32m$ubic_status\e[0m"    # green
            : "\e[31m$ubic_status\e[0m";   # red
        printf "%-15s  %-20s  port:%-5s  %s\n", $name, $color_status, $port, $url;
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION status [service]

  321 status            # all services
  321 status zorda.web  # single service

=cut
