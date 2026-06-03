use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Mojo::Log;

# Authoritative restart: ubic stays the sole supervisor. Instead of a bare
# `ubic restart` (stop+start with no coordination), restart must
#   stop -> wait for the port to actually free -> clear hypnotoad's own
#   pidfile -> start -> port check
# so a fresh `hypnotoad -f` can never find the old manager still alive,
# hot-deploy to it via USR2, and exit (the "phantom restart").

# Build a scan dir with one service. $runner sets the target runner.
sub make_scan {
    my ($runner) = @_;
    my $scan = tempdir(CLEANUP => 1);
    my $repo = path($scan, 'web.demo.do');
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8(<<"YAML");
name: demo.web
entry: bin/app.pl
runner: $runner
live:
  host: demo.do
  port: 39400
  runner: $runner
workers:
  minion:
    cmd: bin/minion-worker.pl
YAML
    return ($scan, $repo);
}

# Records every shell command issued through _run_cmd; pretends the port
# drains and starts instantly so the step sequence is what we assert on.
package RecordingService;
use parent -norequire, 'Deploy::Service';
sub _run_cmd      { my ($s, $cmd) = @_; push @{ $s->{cmds} }, $cmd; return { ok => 1, output => '' } }
sub _check_port   { 1 }
sub _wait_port_free { 1 }
sub _sleep        { }

package main;

sub recording_mgr {
    my ($scan, $runner) = @_;
    my $cfg = Deploy::Config->new(
        app_home => "" . tempdir(CLEANUP => 1),
        scan_dir => "$scan", target => 'live',
    );
    return RecordingService->new(
        config => $cfg, log => Mojo::Log->new(level => 'fatal'), cmds => [],
    );
}

subtest 'hypnotoad restart: stop -> drain -> start, with pidfile cleared' => sub {
    my ($scan) = make_scan('hypnotoad');
    my $mgr = recording_mgr($scan, 'hypnotoad');

    my $r = $mgr->restart('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, [qw(ubic_stop port_drain ubic_start port_check)],
        'restart sequences stop, drain, start, check';

    my @cmds = @{ $mgr->{cmds} };
    ok( (grep { $_ eq 'ubic stop demo.web' }  @cmds), 'issued ubic stop' );
    ok( (grep { $_ eq 'ubic start demo.web' } @cmds), 'issued ubic start' );
    ok( (grep { /rm -f / && /bin\/hypnotoad\.pid/ } @cmds),
        'cleared hypnotoad pidfile before start' );

    # stop must precede start
    my ($si) = grep { $cmds[$_] eq 'ubic stop demo.web' }  0 .. $#cmds;
    my ($ti) = grep { $cmds[$_] eq 'ubic start demo.web' } 0 .. $#cmds;
    ok $si < $ti, 'stop is issued before start';
};

subtest 'morbo restart: no hypnotoad pidfile clear' => sub {
    my ($scan) = make_scan('morbo');
    my $mgr = recording_mgr($scan, 'morbo');

    my $r = $mgr->restart('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, [qw(ubic_stop port_drain ubic_start port_check)],
        'morbo restart still sequenced through stop/drain/start';

    ok( !(grep { /hypnotoad\.pid/ } @{ $mgr->{cmds} }),
        'no hypnotoad.pid removal for a morbo runner' );
};

subtest 'worker restart stays a plain ubic restart' => sub {
    my ($scan) = make_scan('hypnotoad');
    my $mgr = recording_mgr($scan, 'hypnotoad');

    my $r = $mgr->restart('demo.minion');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, ['ubic_restart'],
        'worker (no port) restarts in place';

    ok( !(grep { /^ubic stop/ }      @{ $mgr->{cmds} }), 'no separate stop for worker' );
    ok( !(grep { /hypnotoad\.pid/ }  @{ $mgr->{cmds} }), 'no pidfile clear for worker' );
};

# Drain logic in isolation: poll _check_port until it reports the port free.
package DrainService;
use parent -norequire, 'Deploy::Service';
sub new { my ($c, %a) = @_; my $s = $c->SUPER::new(%a); $s->{slept} = 0; $s }
sub _sleep { $_[0]->{slept}++ }
# Port answers for the first 2 polls, then frees.
sub _check_port { my $s = shift; $s->{polls}++; return $s->{polls} <= 2 ? 1 : 0 }

package StuckService;
use parent -norequire, 'Deploy::Service';
sub new { my ($c, %a) = @_; my $s = $c->SUPER::new(%a); $s->{slept} = 0; $s }
sub _sleep { $_[0]->{slept}++ }
sub _check_port { 1 }   # never frees

package main;

subtest '_wait_port_free returns once the port drains, stops polling early' => sub {
    my $mgr = DrainService->new(log => Mojo::Log->new(level => 'fatal'));
    $mgr->{polls} = 0;
    ok $mgr->_wait_port_free(39400, 15), 'reports freed';
    is $mgr->{slept}, 2, 'slept twice, then saw the port free on the 3rd poll';
};

subtest '_wait_port_free gives up after the timeout when the port never frees' => sub {
    my $mgr = StuckService->new(log => Mojo::Log->new(level => 'fatal'));
    ok !$mgr->_wait_port_free(39400, 3), 'reports not freed';
    is $mgr->{slept}, 3, 'slept exactly timeout times before giving up';
};

done_testing;
