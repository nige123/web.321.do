use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Deploy::Ubic;
use Mojo::Log;

# Hot hypnotoad deploys + health-gated rollback.
#
# Live hypnotoad services move from Ubic::Service::SimpleDaemon (foreground
# child supervision - a USR2 hot swap changes the manager pid and the guardian
# restarts over the top) to Ubic::Service::Common coderefs around hypnotoad's
# own pidfile. Deploys then upgrade via USR2 with zero downtime, gated on a
# health probe, and roll the repo back to the previous sha when the gate fails.

#------------------------------------------------------------------------------
# fixtures
#------------------------------------------------------------------------------

# Scan dir with two services: demo.web declares health; plain.web does not.
sub make_scan {
    my (%opts) = @_;
    my $scan = tempdir(CLEANUP => 1);

    my $demo = path($scan, 'web.demo.do');
    $demo->child('.git')->mkpath;   # deploy()'s repo-exists check is a real `test -d`
    my $health_line = exists $opts{health} ? "health: $opts{health}\n" : "health: /health\n";
    my $pid_line    = $opts{pid_file} ? "pid_file: $opts{pid_file}\n" : '';
    $demo->child('321.yml')->spew_utf8(<<"YAML");
name: demo.web
entry: bin/app.pl
runner: hypnotoad
${health_line}${pid_line}live:
  host: demo.do
  port: 39500
  runner: hypnotoad
workers:
  minion:
    cmd: bin/minion-worker.pl
YAML

    my $plain = path($scan, 'web.plain.do');
    $plain->child('.git')->mkpath;
    $plain->child('321.yml')->spew_utf8(<<"YAML");
name: plain.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: plain.do
  port: 39501
  runner: hypnotoad
YAML

    return ($scan, $demo, $plain);
}

sub make_config {
    my ($scan) = @_;
    return Deploy::Config->new(
        app_home => "" . tempdir(CLEANUP => 1),
        scan_dir => "$scan", target => 'live',
    );
}

#------------------------------------------------------------------------------
# scripted service: records every command; replies from regex-keyed rules.
# A rule value may be a hashref (constant reply) or an arrayref of hashrefs
# consumed one per call (last one repeats).
#------------------------------------------------------------------------------
package ScriptedService;
use parent -norequire, 'Deploy::Service';

sub _reply {
    my ($self, $cmd) = @_;
    for my $rule (@{ $self->{script} // [] }) {
        my ($re, $resp) = @$rule;
        next unless $cmd =~ $re;
        return ref $resp eq 'ARRAY'
            ? (@$resp > 1 ? shift @$resp : $resp->[0])
            : $resp;
    }
    return { ok => 1, output => '' };
}
sub _run_cmd    { my ($s, $cmd) = @_; push @{ $s->{cmds} }, $cmd; return $s->_reply($cmd) }
sub _run_in_dir { my ($s, $dir, $cmd) = @_; push @{ $s->{cmds} }, $cmd; return $s->_reply($cmd) }
sub _check_port { 1 }
sub _sleep      { }

package main;

sub scripted_mgr {
    my ($cfg, @script) = @_;
    return ScriptedService->new(
        config => $cfg, log => Mojo::Log->new(level => 'fatal'),
        cmds => [], script => [@script],
    );
}

my $COMMON_FILE = "use Ubic::Service::Common;\n# marker\n";
my $SIMPLE_FILE = "use Ubic::Service::SimpleDaemon;\n# marker\n";

# Shared happy-path git/cpanm rules.
sub git_rules {
    my (%opts) = @_;
    my $old = $opts{old_sha} // 'aaaa111aaaa111aaaa111aaaa111aaaa111aaaa1';
    my $new = $opts{new_sha} // 'bbbb222bbbb222bbbb222bbbb222bbbb222bbbb2';
    return (
        [ qr/git rev-parse HEAD/ => [ { ok => 1, output => "$old\n" },
                                      { ok => 1, output => "$new\n" } ] ],
        [ qr/git fetch/           => { ok => 1, output => 'updated' } ],
        [ qr/git reset --hard/    => { ok => 1, output => 'reset' } ],
        [ qr/cpanm/               => { ok => 1, output => 'deps ok' } ],
    );
}

#------------------------------------------------------------------------------
# Config: pid_file resolution
#------------------------------------------------------------------------------
subtest 'pid_file defaults beside the entry script, manifest can override' => sub {
    my ($scan, $demo) = make_scan();
    my $svc = make_config($scan)->service('demo.web');
    is $svc->{pid_file}, "$demo/bin/hypnotoad.pid",
        'defaults to <repo>/<entry dir>/hypnotoad.pid';

    ($scan) = make_scan(pid_file => '/tmp/demo-web.pid');
    $svc = make_config($scan)->service('demo.web');
    is $svc->{pid_file}, '/tmp/demo-web.pid', 'manifest pid_file wins';
};

#------------------------------------------------------------------------------
# Ubic render: hypnotoad -> Common; morbo + workers stay SimpleDaemon
#------------------------------------------------------------------------------
subtest 'hypnotoad services render as self-supervising Common files' => sub {
    my ($scan) = make_scan();
    my $cfg  = make_config($scan);
    my $ubic = Deploy::Ubic->new(config => $cfg);

    my $svc  = $cfg->service('demo.web');
    my $file = $ubic->_render_service_file('demo.web', $svc);

    like $file, qr/Ubic::Service::Common/,        'uses Common';
    unlike $file, qr/SimpleDaemon/,               'not SimpleDaemon';
    like $file, qr/\Q$svc->{pid_file}\E/,         'knows the hypnotoad pidfile';
    like $file, qr/setsid/,                       'start detaches into its own session';
    like $file, qr/hypnotoad -f/,                 'runs hypnotoad in the foreground';
    like $file, qr/>>.*demo\.web\.stdout\.log/,   'stdout appended to the manifest log';
    like $file, qr/2>>.*demo\.web\.stderr\.log/,  'stderr appended to the manifest log';
    like $file, qr/result\('running', "pid \$pid"\)/,
        'status reports running (pid N) for the 321 status parser';
    like $file, qr/QUIT/,                         'stop sends graceful QUIT';
};

subtest 'cold start waits out a slow boot (startup migrations)' => sub {
    # An app that runs DB migrations at boot writes the hypnotoad pidfile
    # seconds after the start shell returns. A fire-and-forget start makes
    # ubic's immediate status check report a false "not running" - seen live
    # on love.web 2026-07-19. The generated start must wait for a live
    # manager pid before returning. Behavioural check: eval the real
    # rendered coderefs, with only the shell command swapped for a slow-boot
    # simulator that writes its pid 3s in.
    my $tmp     = tempdir(CLEANUP => 1);
    my $pidfile = path($tmp, 'demo-web.pid');
    my ($scan)  = make_scan(pid_file => "$pidfile");
    my $cfg     = make_config($scan);
    my $ubic    = Deploy::Ubic->new(config => $cfg);

    my $file = $ubic->_render_service_file('demo.web', $cfg->service('demo.web'));
    my $boot = "sh -c 'sleep 3; echo \$\$ > $pidfile; sleep 10' >/dev/null 2>&1 &";
    my $lit  = $boot =~ s/([\\'])/\\$1/gr;
    $file =~ s/^my \$start_cmd = '.*';$/my \$start_cmd = '$lit';/m
        or die 'could not swap start_cmd in the rendered file';

    my $svc_obj = eval $file;
    die $@ if $@;

    eval { $svc_obj->start };
    diag "start threw: $@" if $@;
    is $svc_obj->status->status, 'running',
        'status is running the moment start returns, even after a 3s boot';

    my $booted = $pidfile->exists ? $pidfile->slurp : 0;
    $booted =~ s/\s+//g if $booted;
    kill 'TERM', $booted if $booted;
};

subtest 'morbo and worker services keep the SimpleDaemon form' => sub {
    my ($scan) = make_scan();
    my $cfg  = make_config($scan);
    my $ubic = Deploy::Ubic->new(config => $cfg);

    my $worker = $cfg->service('demo.minion');
    like $ubic->_render_service_file('demo.minion', $worker),
        qr/SimpleDaemon/, 'worker stays SimpleDaemon';

    my $morbo = { %{ $cfg->service('demo.web') }, runner => 'morbo' };
    like $ubic->_render_service_file('demo.web', $morbo),
        qr/SimpleDaemon/, 'morbo stays SimpleDaemon';
};

#------------------------------------------------------------------------------
# deploy: hot path (Common installed, manager alive)
#------------------------------------------------------------------------------
subtest 'deploy of a live Common service hot-swaps via USR2, no stop' => sub {
    my ($scan) = make_scan();
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(),
        [ qr/cat .*ubic\/service\/demo\/web/ => { ok => 1, output => $COMMON_FILE } ],
        [ qr/kill -0|hypnotoad\.pid/ => [ { ok => 1, output => "111\n" },   # pre-deploy: old manager
                                          { ok => 1, output => "111\n" },   # first poll: unchanged
                                          { ok => 1, output => "222\n" } ] ], # then the new manager
        [ qr/curl .*\/health/ => { ok => 1, output => '' } ],
    );

    my $r = $mgr->deploy('demo.web');
    is $r->{status}, 'success', 'deploy succeeds' or diag explain $r;

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( (grep { $_ eq 'hot_deploy' } @steps),   'hot_deploy step present' );
    ok( (grep { $_ eq 'health_check' } @steps), 'health gate ran' );
    ok( !(grep { $_ eq 'ubic_stop' } @steps),   'service never stopped' );

    ok( (grep { /kill -USR2 111/ } @{ $mgr->{cmds} }), 'sent USR2 to the old manager' );
};

#------------------------------------------------------------------------------
# deploy: transition (installed file still SimpleDaemon) falls back to bounce
#------------------------------------------------------------------------------
subtest 'first deploy after upgrade bounces once (SimpleDaemon installed)' => sub {
    my ($scan) = make_scan();
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(),
        [ qr/cat .*ubic\/service\/demo\/web/ => { ok => 1, output => $SIMPLE_FILE } ],
        [ qr/curl .*\/health/ => { ok => 1, output => '' } ],
    );

    my $r = $mgr->deploy('demo.web');
    is $r->{status}, 'success', 'deploy succeeds' or diag explain $r;

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( (grep { $_ eq 'ubic_stop' } @steps),  'cold bounce: stop' );
    ok( (grep { $_ eq 'ubic_start' } @steps), 'cold bounce: start' );
    ok( !(grep { $_ eq 'hot_deploy' } @steps), 'no USR2 against a guardian-supervised manager' );
};

#------------------------------------------------------------------------------
# health gate: failure after a successful swap rolls back and re-swaps
#------------------------------------------------------------------------------
subtest 'failed health check rolls back to the previous sha and re-swaps' => sub {
    my ($scan) = make_scan();
    my $old = 'aaaa111aaaa111aaaa111aaaa111aaaa111aaaa1';
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(old_sha => $old),
        [ qr/cat .*ubic\/service\/demo\/web/ => { ok => 1, output => $COMMON_FILE } ],
        [ qr/kill -0|hypnotoad\.pid/ => [ { ok => 1, output => "111\n" },  # pre-deploy
                                          { ok => 1, output => "222\n" },  # swap took
                                          { ok => 1, output => "222\n" },  # rollback pre-swap read
                                          { ok => 1, output => "333\n" } ] ], # rollback swap took
        # health: fail repeatedly for the new code, succeed after rollback.
        [ qr/curl .*\/health/ => [ ( { ok => 0, output => '' } ) x 10,
                                     { ok => 1, output => '' } ] ],
    );

    my $r = $mgr->deploy('demo.web');
    is $r->{status}, 'rolled_back', 'deploy reports rolled_back' or diag explain $r;
    like $r->{message}, qr/aaaa111/, 'message names the restored sha';

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( (grep { $_ eq 'rollback_git' } @steps),   'repo reset to previous sha' );
    ok( (grep { $_ eq 'rollback_cpanm' } @steps), 'deps restored for previous sha' );

    ok( (grep { /git reset --hard \Q$old\E/ } @{ $mgr->{cmds} }),
        'reset targets the captured pre-deploy sha' );
    is scalar(grep { /kill -USR2/ } @{ $mgr->{cmds} }), 2,
        'second USR2 re-swaps back to the old code';
};

#------------------------------------------------------------------------------
# hot swap that never takes: old manager kept serving, rollback git only
#------------------------------------------------------------------------------
subtest 'swap that never takes rolls back the repo without a second swap' => sub {
    my ($scan) = make_scan();
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(),
        [ qr/cat .*ubic\/service\/demo\/web/ => { ok => 1, output => $COMMON_FILE } ],
        [ qr/kill -0|hypnotoad\.pid/ => { ok => 1, output => "111\n" } ],  # pid never changes
        [ qr/curl .*\/health/ => { ok => 1, output => '' } ],
    );

    my $r = $mgr->deploy('demo.web');
    is $r->{status}, 'rolled_back', 'reported rolled_back' or diag explain $r;
    like $r->{message}, qr/kept serving/i, 'explains the old release never stopped';

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( (grep { $_ eq 'rollback_git' } @steps), 'repo reset' );
    is scalar(grep { /kill -USR2/ } @{ $mgr->{cmds} }), 1,
        'no second USR2 - the old manager never left';
};

#------------------------------------------------------------------------------
# gate choice: undeclared health -> port gate only
#------------------------------------------------------------------------------
subtest 'service without a declared health path gates on the port only' => sub {
    my ($scan) = make_scan();
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(),
        [ qr/cat .*ubic\/service\/plain\/web/ => { ok => 1, output => $COMMON_FILE } ],
        [ qr/kill -0|hypnotoad\.pid/ => [ { ok => 1, output => "111\n" },
                                          { ok => 1, output => "222\n" } ] ],
    );

    my $r = $mgr->deploy('plain.web');
    is $r->{status}, 'success', 'deploy succeeds' or diag explain $r;

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( (grep { $_ eq 'port_check' } @steps),    'port gate ran' );
    ok( !(grep { $_ eq 'health_check' } @steps), 'no health_check step' );
    ok( !(grep { /curl .*\/health/ } @{ $mgr->{cmds} }), 'no health curl issued' );
};

#------------------------------------------------------------------------------
# dev deploys (skip_git) never roll back - there is nothing to roll to
#------------------------------------------------------------------------------
subtest 'dev deploy failing its gate reports error, no rollback' => sub {
    my ($scan) = make_scan();
    my $mgr = scripted_mgr(make_config($scan),
        git_rules(),
        [ qr/cat .*ubic\/service\/demo\/web/ => { ok => 1, output => $COMMON_FILE } ],
        [ qr/kill -0|hypnotoad\.pid/ => [ { ok => 1, output => "111\n" },
                                          { ok => 1, output => "222\n" } ] ],
        [ qr/curl .*\/health/ => { ok => 0, output => '' } ],
    );

    my $r = $mgr->deploy('demo.web', skip_git => 1);
    is $r->{status}, 'error', 'reported as error';

    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok( !(grep { /^rollback/ } @steps), 'no rollback steps' );
};

done_testing;
