package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    $self->config->target($target);
    my $r = $transport->run("ubic start $name");
    say "  $r->{output}" if $r->{output} && $r->{output} =~ /\S/;

    # Verify it's actually running
    sleep 1;
    my $check = $transport->run("ubic status $name");
    my $running = $check->{output} && $check->{output} =~ /running/;

    my $svc  = $self->config->service($name);
    my $port = $svc->{port} // '?';
    my $host = $svc->{host} // 'localhost';
    my $url  = $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";

    if ($running) {
        say "  \e[32m$name running\e[0m ($target)  port:$port  $url";
    } else {
        say "  \e[31m$name not running\e[0m after start";
        say "";
        say "  Next: check logs:";
        say "    321 logs $name --stderr";
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

=cut
