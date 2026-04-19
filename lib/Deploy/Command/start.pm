package Deploy::Command::start;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Start a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);
    my $r = $transport->run("ubic start $name");
    if ($r->{ok}) {
        my $svc  = $self->config->service($name);
        my $port = $svc->{port} // '?';
        my $host = $svc->{host} // 'localhost';
        my $url  = $host ne 'localhost' ? "https://$host/" : "http://localhost:$port/";
        say "  $name started ($target)  port:$port  $url";
    } else {
        say "  $name start failed: $r->{output}";
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION start <service>

=cut
