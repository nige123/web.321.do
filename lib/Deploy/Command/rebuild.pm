package Deploy::Command::rebuild;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Regenerate all ubic service files';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my (undef, $target) = $self->parse_target(@args);
    $self->config->target($target);

    say "Rebuilding ubic service files ($target)...";

    my $ubic = $self->ubic;
    my $is_remote = 0;
    my $transport;

    # For remote targets, detect remote env and set up transport
    my $first_svc_name = $self->config->service_names->[0];
    if ($first_svc_name) {
        $transport = $self->transport_for($first_svc_name, $target);
        my $svc = $self->config->service($first_svc_name);
        if ($svc->{ssh}) {
            $is_remote = 1;
            $ubic->transport($transport);
            $ubic->detect_remote;
            say "  Remote: home=" . $ubic->remote_home . " perlbrew=" . $ubic->perlbrew_root;
        }
    }

    for my $name (@{ $self->config->service_names }) {
        my $gen = $ubic->generate($name);
        if ($gen->{status} eq 'ok') {
            if ($is_remote) {
                $ubic->upload_remote($transport, $name, $gen);
                say "  $name -> remote";
            } else {
                say "  $name -> $gen->{path}";
            }
        } else {
            say "  $name: $gen->{message}";
        }
    }

    say "Done.";
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION rebuild [target]

  Regenerates all ubic service files.

  321 rebuild         # local dev
  321 rebuild live    # remote: generates with remote paths, uploads via SSH

=cut
