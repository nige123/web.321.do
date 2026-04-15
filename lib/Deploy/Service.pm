package Deploy::Service;

use Mojo::Base -base, -signatures;
use Mojo::IOLoop;
use Path::Tiny qw(path);
use POSIX qw(strftime);

has 'config';     # Deploy::Config instance
has 'log';        # Mojo::Log instance
has 'ubic_mgr';   # Deploy::Ubic instance

sub status ($self, $name) {
    my $svc = $self->config->service($name);
    return undef unless $svc;

    my $pid = $self->_get_pid($name, $svc);
    my $git_sha = $self->_git_sha($svc->{repo});
    my $port_ok = $self->_check_port($svc->{port});

    return {
        name    => $name,
        pid     => $pid,
        port    => $svc->{port},
        running => ($pid && $port_ok) ? \1 : \0,
        git_sha => $git_sha,
        repo    => $svc->{repo},
        branch  => $svc->{branch},
        mode    => $svc->{mode} // 'production',
        runner  => $svc->{runner} // 'hypnotoad',
        host    => $svc->{host} // 'localhost',
        ($svc->{docs}  ? (docs  => $svc->{docs})  : ()),
        ($svc->{admin} ? (admin => $svc->{admin}) : ()),
    };
}

sub all_status ($self) {
    my @results;
    for my $name (@{ $self->config->service_names }) {
        push @results, $self->status($name);
    }
    return \@results;
}

sub deploy ($self, $name, %opts) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $skip_git = $opts{skip_git} // 0;
    my @steps;

    my $s = $self->_step_apt_deps($svc);
    push @steps, $s;
    my $apt_ok = ref $s->{success} ? ${$s->{success}} : $s->{success};
    return $self->_deploy_result($name, 'error', 'System packages missing', \@steps)
        unless $apt_ok;

    unless ($skip_git) {
        $s = $self->_step_git_pull($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Git pull failed', \@steps)
            unless $s->{success};
    }

    $s = $self->_step_cpanm($svc);
    push @steps, $s;
    $self->log->warn("cpanm failed for $name: $s->{output}") unless $s->{success};

    if (-x "$svc->{repo}/bin/migrate") {
        $s = $self->_step_migrate($svc);
        push @steps, $s;
        return $self->_deploy_result($name, 'error', 'Migration failed', \@steps)
            unless $s->{success};
    }

    if ($self->ubic_mgr) {
        my $gen = $self->ubic_mgr->generate($name);
        push @steps, { step => 'generate_ubic', success => \1, output => "Generated: $gen->{path}" };
    }

    $s = $self->_step_ubic_restart($name);
    push @steps, $s;
    return $self->_deploy_result($name, 'error', 'Ubic restart failed', \@steps)
        unless $s->{success};

    sleep 2;
    $s = $self->_step_port_check($svc);
    push @steps, $s;

    $self->_log_deploy($name, \@steps);

    my $tag = $skip_git ? ' (dev)' : '';
    my $port_ok = ref $s->{success} ? ${$s->{success}} : $s->{success};
    my $final_status = $port_ok ? 'success' : 'error';
    my $final_msg = $port_ok
        ? "Deployed $name$tag successfully"
        : "Deployed $name$tag but port check failed";
    return $self->_deploy_result($name, $final_status, $final_msg, \@steps);
}

sub _step_apt_deps ($self, $svc) {
    my ($ok, $out) = $self->_check_apt_deps($svc);
    return { step => 'apt_deps', success => $ok ? \1 : \0, output => $out };
}

sub _step_git_pull ($self, $svc) {
    my $branch = $svc->{branch} // 'master';
    my ($ok, $out) = $self->_run_in_dir($svc->{repo},
        "git fetch origin && git reset --hard origin/$branch");
    return { step => 'git_pull', success => $ok, output => $out };
}

sub _step_cpanm ($self, $svc) {
    my ($ok, $out) = $self->_run_in_dir($svc->{repo}, $self->_cpanm_cmd($svc->{perlbrew}));
    return { step => 'cpanm', success => $ok, output => $out };
}

sub _step_ubic_restart ($self, $name) {
    my ($ok, $out) = $self->_run_cmd("ubic restart $name");
    return { step => 'ubic_restart', success => $ok, output => $out };
}

sub _step_migrate ($self, $svc) {
    my $repo = $svc->{repo};
    my $env_prefix = "PERL5LIB=$repo/local/lib/perl5 PATH=$repo/local/bin:\$PATH";
    my ($ok, $out) = $self->_run_in_dir($repo, "$env_prefix ./bin/migrate");
    return { step => 'migrate', success => $ok, output => $out };
}

sub _step_port_check ($self, $svc) {
    my $ok = $self->_check_port($svc->{port});
    return {
        step    => 'port_check',
        success => $ok ? \1 : \0,
        output  => $ok ? "Port $svc->{port} responding" : "Port $svc->{port} not responding",
    };
}

sub deploy_dev ($self, $name) {
    return $self->deploy($name, skip_git => 1);
}

sub _check_apt_deps ($self, $svc) {
    my $deps = $svc->{apt_deps} // [];
    return (1, 'no apt_deps declared') unless @$deps;

    my @missing;
    for my $pkg (@$deps) {
        push @missing, $pkg if system("dpkg -s \Q$pkg\E >/dev/null 2>&1") != 0;
    }

    return (1, 'all installed: ' . join(' ', @$deps)) unless @missing;

    my $cmd = 'sudo apt install -y ' . join(' ', @missing);
    return (0, "Missing system packages: " . join(', ', @missing) . "\n\nRun:\n  $cmd");
}

sub _cpanm_cmd ($self, $perlbrew) {
    # Install into ./local/ so each repo owns its dep tree. Runtime env
    # (PERL5LIB/PATH) is wired up by Deploy::Ubic when generating the
    # service wrapper.
    my $cmd = 'cpanm -L local --notest --installdeps .';
    return $cmd unless $perlbrew;
    return "bash -lc 'source ~/perl5/perlbrew/etc/bashrc && perlbrew use $perlbrew && $cmd'";
}

sub _deploy_result ($self, $name, $status, $message, $steps) {
    return {
        status  => $status,
        message => $message,
        data    => {
            service => $name,
            steps   => $steps,
            timestamp => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        },
    };
}

sub _run_in_dir ($self, $dir, $cmd, %opts) {
    my $timeout = $opts{timeout} // 600;
    $self->log->info("Running: cd $dir && $cmd");
    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm $timeout;
        my $result = `cd \Q$dir\E && $cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;
    if ($@) {
        return (0, "Error: $@");
    }
    return ($? == 0, $output // '');
}

sub _run_cmd ($self, $cmd) {
    $self->log->info("Running: $cmd");
    my $output = eval {
        local $SIG{ALRM} = sub { die "Command timed out\n" };
        alarm 120;
        my $result = `$cmd 2>&1`;
        alarm 0;
        $result;
    };
    alarm 0;
    if ($@) {
        return (0, "Error: $@");
    }
    return ($? == 0, $output // '');
}

sub _get_pid ($self, $name, $svc) {
    # Use ubic status to get pid — works for both morbo and hypnotoad
    my $output = `ubic status $name 2>&1`;
    if ($output =~ /running \(pid (\d+)\)/) {
        return $1;
    }

    # Fallback: check hypnotoad.pid
    my $pidfile = path($svc->{repo}, 'hypnotoad.pid');
    return undef unless $pidfile->exists;
    my $pid = $pidfile->slurp;
    $pid =~ s/\s+//g;
    return undef unless $pid =~ /^\d+$/;
    return kill(0, $pid) ? $pid : undef;
}

sub _git_sha ($self, $repo) {
    my $sha = `cd \Q$repo\E && git rev-parse --short HEAD 2>/dev/null`;
    chomp $sha if $sha;
    return $sha || undef;
}

sub _check_port ($self, $port) {
    return 0 unless $port;
    eval {
        require IO::Socket::INET;
        my $sock = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        return 0 unless $sock;
        close $sock;
    };
    return $@ ? 0 : 1;
}

sub _log_deploy ($self, $name, $steps) {
    my $dir = path('/tmp/321.do/deploys');
    $dir->mkpath;
    my $timestamp = strftime('%Y%m%d-%H%M%S', localtime);
    my $logfile = $dir->child("$name-$timestamp.log");

    my @lines;
    push @lines, "Deploy: $name at $timestamp";
    push @lines, "=" x 40;
    for my $step (@$steps) {
        my $ok = ref $step->{success} ? ${$step->{success}} : $step->{success};
        push @lines, sprintf("[%s] %s", $ok ? 'OK' : 'FAIL', $step->{step});
        push @lines, "  $step->{output}" if $step->{output};
    }
    $logfile->spew_utf8(join("\n", @lines) . "\n");
    $self->log->info("Deploy log written to $logfile");
}

1;
