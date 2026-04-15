package Deploy::Command::list;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'List all services';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    for my $name (@{ $self->config->service_names }) {
        my $svc    = $self->config->service($name);
        my $mode   = $svc->{mode}   // 'production';
        my $runner = $svc->{runner} // 'hypnotoad';
        my $port   = $svc->{port}   // "\x{2014}";
        my $tag    = $mode eq 'development' ? "\e[35mDEV\e[0m" : "\e[32mLIVE\e[0m";
        printf "  %-20s %s  %-10s  port %s\n", $name, $tag, $runner, $port;
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION list

  321 list   # show all services with mode, runner, port

=cut
