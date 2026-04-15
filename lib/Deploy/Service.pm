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
    my $repo   = $svc->{repo};
    my $branch = $svc->{branch} // 'master';
    my ($ok, $out);

    unless ($skip_git) {
        ($ok, $out) = $self->_run_in_dir($repo, "git fetch origin && git reset --hard origin/$branch");
        push @steps, { step => 'git_pull', success => $ok, output => $out };
        return $self->_deploy_result($name, 'error', 'Git pull failed', \@steps) unless $ok;
    }

    ($ok, $out) = $self->_run_in_dir($repo, $self->_cpanm_cmd($svc->{perlbrew}));
    push @steps, { step => 'cpanm', success => $ok, output => $out };
    $self->log->warn("cpanm failed for $name: $out") unless $ok;

    if ($self->ubic_mgr) {
        my $gen = $self->ubic_mgr->generate($name);
        push @steps, { step => 'generate_ubic', success => \1, output => "Generated: $gen->{path}" };
    }

    ($ok, $out) = $self->_run_cmd("ubic restart $name");
    push @steps, { step => 'ubic_restart', success => $ok, output => $out };
    return $self->_deploy_result($name, 'error', 'Ubic restart failed', \@steps) unless $ok;

    sleep 2;
    my $port_ok = $self->_check_port($svc->{port});
    push @steps, { step => 'port_check', success => $port_ok ? \1 : \0, output => $port_ok ? "Port $svc->{port} responding" : "Port $svc->{port} not responding" };

    $self->_log_deploy($name, \@steps);

    my $tag = $skip_git ? ' (dev)' : '';
    my $final_status = $port_ok ? 'success' : 'error';
    my $final_msg = $port_ok
        ? "Deployed $name$tag successfully"
        : "Deployed $name$tag but port check failed";
    return $self->_deploy_result($name, $final_status, $final_msg, \@steps);
}

sub deploy_dev ($self, $name) {
    return $self->deploy($name, skip_git => 1);
}

sub _cpanm_cmd ($self, $perlbrew) {
    my $cmd = 'cpanm --notest --installdeps .';
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
