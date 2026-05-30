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

done_testing;
