package Deploy::Local;

use Mojo::Base -base, -signatures;
use File::Copy qw(copy);

has 'perlbrew';    # if set, wrap commands via perlbrew
has 'log';         # optional Mojo::Log instance

# Wrap a command with perlbrew if the perlbrew attribute is set.
sub _wrap ($self, $cmd) {
    # Local commands inherit the current environment — no perlbrew wrapping needed.
    # The 321 process is already running under perlbrew, so ubic/cpanm/etc are on PATH.
    return $cmd;
}

# run($cmd, %opts) — execute command via backtick, return {ok, output, exit_code}.
# Supports timeout option (default 120s).
sub run ($self, $cmd, %opts) {
    my $timeout = $opts{timeout} // 120;
    my $full_cmd = $self->_wrap($cmd);
    if ($self->log) {
        $self->log->info("Running: $full_cmd");
    }
    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `$full_cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;
    if ($@) {
        return { ok => 0, output => "Error: $@", exit_code => -1 };
    }
    my $exit_code = $? >> 8;
    return { ok => ($exit_code == 0 ? 1 : 0), output => $output // '', exit_code => $exit_code };
}

# run_in_dir($dir, $cmd, %opts) — cd to dir then run. Same return format.
sub run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout = $opts{timeout} // 120;
    my $full_cmd = $self->_wrap("cd \Q$dir\E && $cmd");
    if ($self->log) {
        $self->log->info("Running: $full_cmd");
    }
    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `$full_cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;
    if ($@) {
        return { ok => 0, output => "Error: $@", exit_code => -1 };
    }
    my $exit_code = $? >> 8;
    return { ok => ($exit_code == 0 ? 1 : 0), output => $output // '', exit_code => $exit_code };
}

# run_steps(\@steps, %opts) — run array of {cmd, label} hashes in sequence,
# abort on first failure. Return {ok, steps => [results]}.
sub run_steps ($self, $steps, %opts) {
    my @results;
    for my $step (@$steps) {
        my $result = $self->run($step->{cmd}, %opts);
        $result->{label} = $step->{label} // $step->{cmd};
        push @results, $result;
        unless ($result->{ok}) {
            return { ok => 0, steps => \@results };
        }
    }
    return { ok => 1, steps => \@results };
}

# stream($cmd, %opts) — open pipe, print each line or call on_line callback.
# Return {ok}.
sub stream ($self, $cmd, %opts) {
    my $on_line = $opts{on_line};
    my $full_cmd = $self->_wrap($cmd);
    if ($self->log) {
        $self->log->info("Streaming: $full_cmd");
    }
    open my $fh, '-|', "$full_cmd 2>&1"
        or return { ok => 0 };
    while (my $line = <$fh>) {
        if ($on_line) {
            $on_line->($line);
        } else {
            print $line;
        }
    }
    close $fh;
    return { ok => ($? == 0 ? 1 : 0) };
}

# upload($local, $remote) — local file copy. Return {ok, output}.
sub upload ($self, $local, $remote) {
    my $ok = copy($local, $remote);
    unless ($ok) {
        return { ok => 0, output => "File::Copy failed: $!" };
    }
    return { ok => 1, output => "Copied $local -> $remote" };
}

1;
