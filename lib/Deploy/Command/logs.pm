package Deploy::Command::logs;

use Mojo::Base 'Deploy::Command', -signatures;

has description => 'Tail, search, or analyse service logs';
has usage => sub ($self) { $self->extract_usage };

sub run ($self, @args) {
    my %opts;
    my @positional;
    while (defined(my $arg = shift @args)) {
        if ($arg =~ /^--stderr$/)        { $opts{type}   = 'stderr' }
        elsif ($arg =~ /^--stdout$/)     { $opts{type}   = 'stdout' }
        elsif ($arg =~ /^--ubic$/)       { $opts{type}   = 'ubic' }
        elsif ($arg =~ /^--search=(.+)/) { $opts{search} = $1 }
        elsif ($arg =~ /^--analyse$/)    { $opts{analyse}= 1 }
        elsif ($arg =~ /^--follow$/)     { $opts{follow} = 1 }
        elsif ($arg =~ /^-f$/)           { $opts{follow} = 1 }
        elsif ($arg =~ /^--n=(\d+)/)     { $opts{n}      = $1 }
        elsif ($arg =~ /^-n(\d+)$/)      { $opts{n}      = $1 }
        elsif ($arg =~ /^-n$/)           { $opts{n}      = shift @args }
        else                             { push @positional, $arg }
    }

    my ($svc_input, $target) = $self->parse_target(@positional);
    die $self->usage unless $svc_input;
    my $name = $self->resolve_service($svc_input);
    my $transport = $self->transport_for($name, $target);

    my $log_mgr = $self->app->log_mgr_obj;
    $log_mgr->transport($transport);

    if ($opts{search}) {
        my $r = $log_mgr->search($name, $opts{search},
            $opts{type} // 'stderr', $opts{n} // 50);
        if ($r->{status} eq 'success') {
            for my $m (@{ $r->{data}{matches} // [] }) {
                ref $m eq 'HASH' ? say "$m->{line}:$m->{text}" : say $m;
            }
        } else {
            say "Error: $r->{message}";
        }
    } elsif ($opts{analyse}) {
        my $r = $log_mgr->analyse($name, $opts{n} // 1000);
        if ($r->{status} eq 'success') {
            my $d = $r->{data};
            my $errors   = $d->{errors}   // [];
            my $warnings = $d->{warnings} // [];
            say "Errors: " . scalar(@$errors) . "  Warnings: " . scalar(@$warnings);
            for my $e (@$errors) {
                printf "  [%d] %s\n", $e->{count}, $e->{pattern};
            }
        } else {
            say "Error: $r->{message}";
        }
    } elsif ($opts{follow}) {
        # Old behaviour, opt-in: tail -f, runs until Ctrl-C. Useful for
        # humans watching a service live.
        $log_mgr->stream($name, type => $opts{type} // 'stdout');
    } else {
        # Default: one-shot snapshot of the last N lines and exit.
        # Agent-friendly — no Ctrl-C needed.
        my $type = $opts{type} // 'stdout';
        my $n    = $opts{n}    // 100;
        $n = 1000 if $n > 1000;
        my $r = $log_mgr->tail($name, $type, $n);
        if ($r->{status} eq 'success') {
            say $_ for @{ $r->{data}{lines} // [] };
        } else {
            say "Error: $r->{message}";
        }
    }
}

1;

=head1 SYNOPSIS

  Usage: APPLICATION logs <service> [target] [options]

  Default: prints the last 100 lines of stdout and exits (agent-friendly).

  Options:
    --stderr        Read stderr instead of stdout
    --stdout        Read stdout (the default)
    --ubic          Read the ubic supervisor log
    -n N            Number of lines (default 100, max 1000)
    --n=N           Same as -n N
    --follow, -f    tail -f mode (streams until Ctrl-C)
    --search=TERM   Search the log for TERM (returns matches, exits)
    --analyse       Show error/warning summary (exits)

  Examples:
    321 logs love.web                    # last 100 stdout lines, dev
    321 logs love.web live               # last 100 stdout lines, live
    321 logs love.web live --stderr -n 50
    321 logs love.web live --search=ERROR
    321 logs love.web -f                 # follow (Ctrl-C to stop)

=cut
