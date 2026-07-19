package Deploy::Command::test;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Run tests for a service';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my ($svc_input, $target) = $self->parse_target(@args);
    die $self->usage unless $svc_input;
    my @names = $self->resolve_service($svc_input);
    $self->config->target($target);

    my $failed = 0;
    for my $name (@names) {
        $failed += $self->_test_one($name, $target);
    }
    exit($failed ? 1 : 0);
}

sub _test_one ($self, $name, $target) {
    my $svc = $self->config->service($name);
    my $test_cmd = $svc->{test};

    unless ($test_cmd) {
        say "  \e[33m$name: no test command configured\e[0m";
        say "  Add to 321.yml: test: prove -lr t";
        return 0;
    }

    say "  Testing $name...";
    say "  > $test_cmd";
    say "";

    my $transport = $self->transport_for($name, $target);
    my $r = $transport->stream($self->test_command($svc));

    if ($r->{ok}) {
        say "";
        say "  \e[32m$name: tests passed\e[0m";
        return 0;
    } else {
        say "";
        say "  \e[31m$name: tests failed\e[0m";
        return 1;
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION test <service> [target]

  Run tests for a service. The test command is configured in 321.yml:

    test: prove -lr t

  The command runs inside the repo with the bundled local-lib pinned
  (PERL5LIB=<repo>/local/lib/perl5, <repo>/local/bin on PATH) - the same
  env deploys and ubic services get, so a bare `prove -lr t` just works.

  321 test 123.api         # run tests locally
  321 test 123             # run tests for all 123.* services

=cut
