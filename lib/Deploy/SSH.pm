package Deploy::SSH;

use Mojo::Base -base, -signatures;

has 'user';       # remote username
has 'host';       # remote hostname or IP
has 'key';        # path to SSH private key
has 'perlbrew';   # if set, wrap commands via perlbrew (e.g. 'perl-5.42.0')
has 'log';        # optional Mojo::Log instance

# _shell_escape($str) — escape single quotes so $str can be placed inside '…'.
# Turns: it's  into: it'\''s
sub _shell_escape ($self, $str) {
    $str =~ s/'/'\\''/g;
    return $str;
}

# _wrap_perlbrew($cmd) — always source perlbrew if available (tools like ubic
# and cpanm live there), and select a specific version if configured.
sub _wrap_perlbrew ($self, $cmd) {
    my $pb = $self->perlbrew;
    if ($pb) {
        return "source ~/perl5/perlbrew/etc/bashrc && perlbrew use $pb && $cmd";
    }
    # Even without a specific version, source perlbrew so its tools are on PATH
    return "test -f ~/perl5/perlbrew/etc/bashrc && source ~/perl5/perlbrew/etc/bashrc; $cmd";
}

# _ssh_cmd($cmd) — build full ssh command string.
sub _ssh_cmd ($self, $cmd) {
    my $wrapped  = $self->_wrap_perlbrew($cmd);
    my $escaped  = $self->_shell_escape($wrapped);
    return sprintf(
        "ssh -i %s -o StrictHostKeyChecking=accept-new -T %s\@%s '%s'",
        $self->key,
        $self->user,
        $self->host,
        $escaped,
    );
}

# _ssh_cmd_in_dir($dir, $cmd) — build ssh command with cd prefix.
sub _ssh_cmd_in_dir ($self, $dir, $cmd) {
    return $self->_ssh_cmd("cd $dir && $cmd");
}

# _scp_cmd($local, $remote) — build scp command string.
sub _scp_cmd ($self, $local, $remote) {
    return sprintf(
        "scp -i %s %s %s\@%s:%s",
        $self->key,
        $local,
        $self->user,
        $self->host,
        $remote,
    );
}

# run($cmd, %opts) — execute command over SSH, return {ok, output, exit_code}.
# Supports timeout option (default 120s).
sub run ($self, $cmd, %opts) {
    my $timeout  = $opts{timeout} // 120;
    my $full_cmd = $self->_ssh_cmd($cmd);
    warn "  [ssh] $cmd\n" if $ENV{VERBOSE};
    if ($self->log) {
        $self->log->info("SSH run: $full_cmd");
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

# run_in_dir($dir, $cmd, %opts) — cd to remote dir then run. Same return format.
sub run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout  = $opts{timeout} // 120;
    my $full_cmd = $self->_ssh_cmd_in_dir($dir, $cmd);
    warn "  [ssh] cd $dir && $cmd\n" if $ENV{VERBOSE};
    if ($self->log) {
        $self->log->info("SSH run_in_dir: $full_cmd");
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

# stream($cmd, %opts) — open SSH pipe, stream lines (or call on_line callback).
# Return {ok}.
sub stream ($self, $cmd, %opts) {
    my $on_line  = $opts{on_line};
    my $full_cmd = $self->_ssh_cmd($cmd);
    if ($self->log) {
        $self->log->info("SSH stream: $full_cmd");
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

# upload($local, $remote) — scp file to remote host. Return {ok, output}.
sub upload ($self, $local, $remote) {
    my $full_cmd = $self->_scp_cmd($local, $remote);
    if ($self->log) {
        $self->log->info("SCP upload: $full_cmd");
    }
    my $output = `$full_cmd 2>&1`;
    my $exit_code = $? >> 8;
    if ($exit_code != 0) {
        return { ok => 0, output => $output // '' };
    }
    return { ok => 1, output => "Uploaded $local -> ${\$self->user}\@${\$self->host}:$remote" };
}

1;
