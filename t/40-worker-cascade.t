use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

# Fixture: a scan_dir containing one repo whose 321.yml declares two workers
# (printer, mailer) plus a no-workers control repo. Returns the scan_dir path
# and the tempdir handles to keep them alive.
sub make_fixture {
    my $home_obj = tempdir(CLEANUP => 1);
    my $scan_obj = tempdir(CLEANUP => 1);

    my $repo = path($scan_obj, 'web.demo.do');
    $repo->mkpath;
    system("cd $repo && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
    path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
workers:
  printer:
    cmd: bin/printer-worker.pl
  mailer:
    cmd: bin/mailer-worker.pl
live:
  host: demo.do
  port: 39400
  runner: hypnotoad
YAML

    my $plain = path($scan_obj, 'web.plain.do');
    $plain->mkpath;
    system("cd $plain && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
    path($plain, '321.yml')->spew_utf8(<<'YAML');
name: plain.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: plain.do
  port: 39401
  runner: hypnotoad
YAML

    return ("$home_obj", "$scan_obj", $scan_obj, $home_obj);
}

subtest 'workers_of returns sorted worker names for a main with workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('demo.web'), ['demo.mailer', 'demo.printer'],
        'returns sorted [demo.mailer, demo.printer]';
};

subtest 'workers_of returns [] for a worker name' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('demo.printer'), [], 'worker target → empty list';
};

subtest 'workers_of returns [] for a main with no workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('plain.web'), [], 'no workers: → empty list';
};

subtest 'workers_of returns [] for an unknown name' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    is_deeply $cfg->workers_of('nope.web'), [], 'unknown → empty list';
};

# Lightweight transport double that records every command run against it
# and returns canned replies keyed by exact command string.
package RecordingTransport {
    sub new {
        my ($class, %args) = @_;
        return bless {
            calls   => [],
            replies => $args{replies} // {},
            default => $args{default} // { ok => 1, output => '' },
        }, $class;
    }
    sub run {
        my ($self, $cmd, %opts) = @_;
        push @{ $self->{calls} }, $cmd;
        return $self->{replies}{$cmd} // $self->{default};
    }
    sub calls { @{ $_[0]{calls} } }
    sub isa  { 0 }
}

# Build a Mojolicious app whose config_obj is the fixture Deploy::Config,
# so Deploy::Command->new(app => $app)->config works.
sub make_app {
    my ($cfg) = @_;
    require Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(config_obj => sub { $cfg });
    return $app;
}

subtest 'cascade_workers runs ubic <action> on every worker in sorted order' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    require Deploy::Command;
    my $app = make_app($cfg);
    my $cmd = Deploy::Command->new(app => $app);
    my $t = RecordingTransport->new;
    my $results = $cmd->cascade_workers('demo.web', 'restart', $t);
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'one ubic restart per worker, sorted order';
    is scalar @$results, 2, 'two result rows';
    is $results->[0]{name}, 'demo.mailer', 'first result names mailer';
    ok  $results->[0]{ok},                 'first result reports ok';
};

subtest 'cascade_workers reverses for stop' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $app = make_app($cfg);
    my $cmd = Deploy::Command->new(app => $app);
    my $t = RecordingTransport->new;
    $cmd->cascade_workers('demo.web', 'stop', $t);
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer'],
        'stop iterates reverse of the sorted list';
};

subtest 'cascade_workers continues after a per-worker failure' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $app = make_app($cfg);
    my $cmd = Deploy::Command->new(app => $app);
    my $t = RecordingTransport->new(replies => {
        'ubic restart demo.mailer' => { ok => 0, output => 'boom' },
    });
    my $results = $cmd->cascade_workers('demo.web', 'restart', $t);
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'second worker still attempted after first failed';
    ok !$results->[0]{ok}, 'mailer result marked failed';
    is $results->[0]{output}, 'boom', 'failure output captured';
    ok  $results->[1]{ok}, 'printer result still ok';
};

subtest 'cascade_workers is a no-op when target has no workers' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $app = make_app($cfg);
    my $cmd = Deploy::Command->new(app => $app);
    my $t = RecordingTransport->new;
    my $results = $cmd->cascade_workers('plain.web', 'restart', $t);
    is_deeply [$t->calls], [], 'no transport calls made';
    is_deeply $results, [], 'empty result list';
};

# Stubbed stop subclass that swaps in a recording transport and skips
# the status command at the end of stop.pm (status would re-instantiate
# its own transport_for and we want to assert on the one we injected).
BEGIN { require Deploy::Command::stop }
package TestStop {
    use parent -norequire, 'Deploy::Command::stop';
    our $TRANSPORT;
    sub transport_for { $TRANSPORT }
    # Skip the trailing status block; it constructs a real Mojolicious
    # status command which isn't what these tests are about.
    sub _show_status { }
}

subtest 'stop demo.web stops workers in reverse, then main' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestStop::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStop->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer', 'ubic stop demo.web'],
        'workers stop reverse-sorted, then main';
};

subtest 'stop demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestStop::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStop->new(app => $app);
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], ['ubic stop demo.printer'],
        'naming a worker stops only that worker';
};

subtest 'stop continues to main even when a worker stop fails' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new(replies => {
        'ubic stop demo.printer' => { ok => 0, output => 'boom' },
    });
    local $TestStop::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStop->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic stop demo.printer', 'ubic stop demo.mailer', 'ubic stop demo.web'],
        'failed worker does not abort cascade or main';
};

BEGIN { require Deploy::Command::restart }

# Stub restart subclass: swap transport, swap svc_mgr for one whose restart
# returns a canned result so we can drive the cascade gate.
package StubSvcMgr {
    sub new { bless { result => $_[1] }, $_[0] }
    sub transport { }
    sub restart   { $_[0]->{result} }
}

package TestRestart {
    use parent -norequire, 'Deploy::Command::restart';
    our ($TRANSPORT, $SVC_MGR);
    sub transport_for      { $TRANSPORT }
    sub svc_mgr            { $SVC_MGR }
    sub ensure_fresh_ubic  { }     # skip ubic file freshness check
    sub print_failure      { }     # silence
}

subtest 'restart demo.web cascades after main success' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'success', message => 'restarted', data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestRestart->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'workers restart after main, sorted order';
};

subtest 'restart demo.web does not cascade when main restart errors' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'error', message => 'nope', data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestRestart->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$t->calls], [], 'main errored → cascade skipped';
};

subtest 'restart demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = RecordingTransport->new;
    local $TestRestart::TRANSPORT = $t;
    local $TestRestart::SVC_MGR = StubSvcMgr->new({
        status => 'success', message => 'restarted', data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestRestart->new(app => $app);
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], [], 'worker name → cascade_workers returns []';
};

BEGIN { require Deploy::Command::start }

package TestStart {
    use parent -norequire, 'Deploy::Command::start';
    our $TRANSPORT;
    sub transport_for     { $TRANSPORT }
    sub ensure_fresh_ubic { }
    # Skip the trailing status command (it constructs its own command).
    sub _show_status      { }
}

# Helper: a recording transport whose ubic status replies say "running",
# so _start_one's "already running" branch fires for the main and workers
# — which still records a 'ubic status' call we can assert on.
sub start_transport_for_already_running {
    return RecordingTransport->new(replies => {
        'ubic status demo.web 2>&1'     => { ok => 1, output => "demo.web\trunning (pid 1234)\n" },
        'ubic status demo.mailer 2>&1'  => { ok => 1, output => "demo.mailer\trunning (pid 1235)\n" },
        'ubic status demo.printer 2>&1' => { ok => 1, output => "demo.printer\trunning (pid 1236)\n" },
    });
}

subtest 'start demo.web cascades to workers in sorted order' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = start_transport_for_already_running();
    local $TestStart::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStart->new(app => $app);
    $cmd->run('demo.web', 'live');
    # Each _start_one runs `ubic status <name> 2>&1` first; if already
    # running, it returns and doesn't call `ubic start`. So the recorded
    # calls are three status checks: main, then workers sorted.
    is_deeply [$t->calls],
        [
            'ubic status demo.web 2>&1',
            'ubic status demo.mailer 2>&1',
            'ubic status demo.printer 2>&1',
        ],
        'main then each worker — sorted';
};

subtest 'start demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $t = start_transport_for_already_running();
    local $TestStart::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStart->new(app => $app);
    $cmd->run('demo.printer', 'live');
    is_deeply [$t->calls], ['ubic status demo.printer 2>&1'],
        'worker target → only that worker is started';
};

subtest 'start demo.web skips worker cascade if main does not come up' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    # Main status: not running; ubic start replies "unknown service" →
    # _start_one returns 0 → cascade skipped. Make check_port fail (port
    # not responding) so we land in the ubic start branch.
    my $t = RecordingTransport->new(replies => {
        'ubic status demo.web 2>&1' => { ok => 1, output => "demo.web\tnot running\n" },
        'curl -s -o /dev/null --connect-timeout 2 http://127.0.0.1:39400/' => { ok => 0, output => '' },
        'ubic start demo.web' => { ok => 1, output => 'unknown service demo.web' },
    });
    local $TestStart::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStart->new(app => $app);
    $cmd->run('demo.web', 'live');
    my @calls = $t->calls;
    ok !(grep { /ubic status demo\.mailer/ } @calls),
        'workers not touched when main fails to start';
};

BEGIN { require Deploy::Command::go }

# Stubbed go subclass: swap transport, stub svc_mgr->deploy, skip the
# nginx/host fixup, skip the install path.
package StubSvcMgrDeploy {
    sub new { bless { result => $_[1] }, $_[0] }
    sub transport { }
    sub deploy { $_[0]->{result} }
}

# Wraps a RecordingTransport so the *first* call (the install probe in
# go.pm) returns 'OK' without being recorded, and every subsequent call
# is delegated to the underlying recorder. This forces go.pm down the
# redeploy branch instead of the install branch.
package TestGoTransport {
    sub new {
        my ($class, $inner) = @_;
        return bless { inner => $inner, first => 1 }, $class;
    }
    sub run {
        my ($self, $cmd, %opts) = @_;
        if ($self->{first}) {
            $self->{first} = 0;
            return { ok => 1, output => "OK\n" };   # install probe passes
        }
        return $self->{inner}->run($cmd, %opts);
    }
    sub isa { 0 }
}

package TestGo {
    use parent -norequire, 'Deploy::Command::go';
    our ($TRANSPORT, $SVC_MGR);
    sub transport_for {
        my ($self, $name, $target) = @_;
        return TestGoTransport->new($TRANSPORT);
    }
    sub svc_mgr        { $SVC_MGR }
    sub _ensure_serving { }       # skip nginx/hosts side trips
}

subtest 'go demo.web cascades to workers after redeploy success' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'success',
        message => 'deployed',
        data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestGo->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$recorder->calls],
        ['ubic restart demo.mailer', 'ubic restart demo.printer'],
        'workers restart after main, sorted order';
};

subtest 'go demo.web does NOT cascade when main deploy errors' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'error',
        message => 'deploy failed',
        data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestGo->new(app => $app);
    $cmd->run('demo.web', 'live');
    is_deeply [$recorder->calls], [], 'cascade skipped on deploy error';
};

subtest 'go demo.printer (worker target) does not cascade' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $recorder = RecordingTransport->new;
    local $TestGo::TRANSPORT = $recorder;
    local $TestGo::SVC_MGR = StubSvcMgrDeploy->new({
        status => 'success',
        message => 'deployed',
        data => { steps => [] },
    });
    my $app = make_app($cfg);
    my $cmd = TestGo->new(app => $app);
    $cmd->run('demo.printer', 'live');
    is_deeply [$recorder->calls], [], 'no cascade when target is a worker';
};

done_testing;
