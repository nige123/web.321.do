use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;

# `321 stop all` and `321 start all` act on every LOCAL service - the ones
# with a dev target - and never reach across to live-only services. Fixture:
#   demo.web  : dev + live, two workers (printer, mailer)
#   solo.web  : dev + live, no workers
#   liveonly.web : live ONLY (no dev target) - must be skipped by *-all.
sub make_fixture {
    my $home_obj = tempdir(CLEANUP => 1);
    my $scan_obj = tempdir(CLEANUP => 1);

    my $demo = path($scan_obj, 'web.demo.do');
    $demo->mkpath;
    path($demo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
workers:
  printer:
    cmd: bin/printer-worker.pl
  mailer:
    cmd: bin/mailer-worker.pl
dev:
  host: demo.do.dev
  port: 39400
  runner: morbo
live:
  host: demo.do
  port: 39400
  runner: hypnotoad
YAML

    my $solo = path($scan_obj, 'web.solo.do');
    $solo->mkpath;
    path($solo, '321.yml')->spew_utf8(<<'YAML');
name: solo.web
entry: bin/app.pl
runner: hypnotoad
dev:
  host: solo.do.dev
  port: 39401
  runner: morbo
live:
  host: solo.do
  port: 39401
  runner: hypnotoad
YAML

    my $live = path($scan_obj, 'web.liveonly.do');
    $live->mkpath;
    path($live, '321.yml')->spew_utf8(<<'YAML');
name: liveonly.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: liveonly.do
  port: 39402
  runner: hypnotoad
YAML

    return ("$home_obj", "$scan_obj", $scan_obj, $home_obj);
}

# Recording transport: logs every command, returns canned replies by exact
# command string (default ok/empty otherwise).
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

sub make_app {
    my ($cfg) = @_;
    require Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(config_obj => sub { $cfg });
    return $app;
}

# --- local_main_services (the shared filter) ---------------------------------

subtest 'local_main_services lists dev-target mains, skips workers and live-only' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'dev');
    require Deploy::Command;
    my $app = make_app($cfg);
    my $cmd = Deploy::Command->new(app => $app);
    is_deeply $cmd->local_main_services, ['demo.web', 'solo.web'],
        'only mains with a dev target, sorted; no workers, no live-only';
};

# --- stop all ----------------------------------------------------------------

BEGIN { require Deploy::Command::stop }
package TestStop {
    use parent -norequire, 'Deploy::Command::stop';
    our $TRANSPORT;
    sub transport_for { $TRANSPORT }
    sub _show_status  { }
}

subtest 'stop all stops every local service (workers reversed) and skips live-only' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'dev');
    my $t = RecordingTransport->new;
    local $TestStop::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStop->new(app => $app);
    $cmd->run('all');
    is_deeply [$t->calls],
        [
            'ubic stop demo.printer',
            'ubic stop demo.mailer',
            'ubic stop demo.web',
            'ubic stop solo.web',
        ],
        'demo workers (reverse) + demo main + solo; liveonly never touched';
};

# --- start all ---------------------------------------------------------------

BEGIN { require Deploy::Command::start }
package TestStart {
    use parent -norequire, 'Deploy::Command::start';
    our $TRANSPORT;
    sub transport_for     { $TRANSPORT }
    sub ensure_fresh_ubic { }
    sub _show_status      { }
}

subtest 'start all starts every local service + workers, skips live-only' => sub {
    my ($home, $scan, $scan_obj, $home_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'dev');
    # Report everything already running so _start_one returns 1 and cascades;
    # the recorded `ubic status` calls show exactly which services were acted on.
    my $t = RecordingTransport->new(replies => {
        'ubic status demo.web 2>&1'     => { ok => 1, output => "demo.web\trunning (pid 1)\n" },
        'ubic status demo.mailer 2>&1'  => { ok => 1, output => "demo.mailer\trunning (pid 2)\n" },
        'ubic status demo.printer 2>&1' => { ok => 1, output => "demo.printer\trunning (pid 3)\n" },
        'ubic status solo.web 2>&1'     => { ok => 1, output => "solo.web\trunning (pid 4)\n" },
    });
    local $TestStart::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestStart->new(app => $app);
    $cmd->run('all');
    is_deeply [$t->calls],
        [
            'ubic status demo.web 2>&1',
            'ubic status demo.mailer 2>&1',
            'ubic status demo.printer 2>&1',
            'ubic status solo.web 2>&1',
        ],
        'each local main then its workers (sorted); liveonly never touched';
};

done_testing;
