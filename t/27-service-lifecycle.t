use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Deploy::Ubic;
use Mojo::Log;

# Stub ubic_mgr that records generate calls and returns a fake path.
package StubUbic;
sub new { bless {}, shift }
sub generate { return { path => '/tmp/stub-ubic-path' } }

# Subclass Deploy::Service to stub out external commands.
package TestService;
use parent -norequire, 'Deploy::Service';
sub _run_cmd  { return (1, 'stubbed') }          # ubic restart always succeeds
sub _check_port { return 1 }                     # port always up
# _run_in_dir is used for cpanm; let it run for real (tempdir repo, cpanfile present)

package main;

# Fixtures: a repo with a local git history plus a stub cpanfile.
sub make_fixture {
    my $home = tempdir(CLEANUP => 1);
    path($home, 'services')->mkpath;
    path($home, 'secrets')->mkpath;

    my $remote = path(tempdir(CLEANUP => 1), 'demo.git')->stringify;
    system("git init -q --bare $remote");

    my $repo = tempdir(CLEANUP => 1);
    system("cd $repo && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q && git branch -M master && git remote add origin $remote && git push -q origin master 2>/dev/null");
    path($repo, 'cpanfile')->spew_utf8("requires 'perl', '5.010';\n");

    path($home, 'services', 'demo.web.yml')->spew_utf8(<<"YAML");
name: demo.web
repo: $repo
branch: master
bin: bin/app.pl
targets:
  live:
    host: demo.do
    port: 39400
    runner: hypnotoad
YAML

    return ($home, $repo);
}

subtest 'deploy returns the same step sequence as before the refactor' => sub {
    my ($home, $repo) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, target => 'live');

    # Build the ubic dir structure so generate() works
    path($repo, 'ubic', 'service', 'demo')->mkpath;

    my $svc_mgr = TestService->new(
        config   => $cfg,
        log      => Mojo::Log->new(level => 'fatal'),
        ubic_mgr => Deploy::Ubic->new(config => $cfg),
    );
    my $r = $svc_mgr->deploy('demo.web', skip_git => 1);
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps,
        [qw(apt_deps cpanm generate_ubic ubic_restart port_check)],
        'full deploy emits the expected step list (skip_git)';
};

subtest '_step_migrate: success' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'echo "applying migration 001"' . "\n");
    chmod 0755, "$repo/bin/migrate";

    my $svc_mgr = Deploy::Service->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $svc = $svc_mgr->config->service('demo.web');
    my $s = $svc_mgr->_step_migrate($svc);

    is $s->{step}, 'migrate',                'step name';
    ok $s->{success},                         'success is truthy';
    like $s->{output}, qr/applying migration 001/, 'migrate output captured';
};

subtest '_step_migrate: failure propagates non-zero exit' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'echo boom >&2' . "\n" . 'exit 7' . "\n");
    chmod 0755, "$repo/bin/migrate";

    my $svc_mgr = Deploy::Service->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $svc = $svc_mgr->config->service('demo.web');
    my $s = $svc_mgr->_step_migrate($svc);

    ok !$s->{success},         'non-zero exit → success false';
    like $s->{output}, qr/boom/, 'stderr captured in output';
};

subtest 'deploy runs bin/migrate when present' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'echo migrated' . "\n");
    chmod 0755, "$repo/bin/migrate";
    path($repo, 'ubic', 'service', 'demo')->mkpath;

    my $cfg = Deploy::Config->new(app_home => $home, target => 'live');
    my $svc_mgr = TestService->new(
        config   => $cfg,
        log      => Mojo::Log->new(level => 'fatal'),
        ubic_mgr => Deploy::Ubic->new(config => $cfg),
    );
    my $r = $svc_mgr->deploy('demo.web', skip_git => 1);
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps,
        [qw(apt_deps cpanm migrate generate_ubic ubic_restart port_check)],
        'migrate slotted between cpanm and ubic_restart';
};

subtest 'deploy aborts before restart when migrate fails' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'exit 1' . "\n");
    chmod 0755, "$repo/bin/migrate";

    my $svc_mgr = TestService->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->deploy('demo.web', skip_git => 1);
    is $r->{status}, 'error',                      'deploy reports error';
    like $r->{message}, qr/Migration failed/i,     'message names the failure';
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    ok !(grep { $_ eq 'ubic_restart' } @steps),    'no restart after failed migrate';
};

subtest 'update: runs git_pull+cpanm+migrate, no restart' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'echo migrated' . "\n");
    chmod 0755, "$repo/bin/migrate";

    my $svc_mgr = TestService->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->update('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, [qw(apt_deps git_pull cpanm migrate)],
        'update skips restart + port_check';
    is $r->{status}, 'success', 'update reports success';
};

subtest 'update: aborts on git_pull failure' => sub {
    my ($home, $repo) = make_fixture();
    # Remove the repo's .git dir so git fetch fails
    path($repo, '.git')->remove_tree({safe => 0});

    my $svc_mgr = TestService->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->update('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, [qw(apt_deps git_pull)], 'short-circuits on git failure';
    is $r->{status}, 'error';
};

subtest 'migrate: runs only the migrate step' => sub {
    my ($home, $repo) = make_fixture();
    path($repo, 'bin')->mkpath;
    path($repo, 'bin/migrate')->spew_utf8('#!/bin/sh' . "\n" . 'echo migrated' . "\n");
    chmod 0755, "$repo/bin/migrate";

    my $svc_mgr = Deploy::Service->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->migrate('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, ['migrate'], 'single step';
    is $r->{status}, 'success';
};

subtest 'migrate: missing bin/migrate reports no-op' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->migrate('demo.web');
    is $r->{status}, 'success',                          'no-op is success';
    like $r->{message}, qr/no bin\/migrate/i,            'message explains';
    is scalar @{ $r->{data}{steps} }, 0,                 'no steps emitted';
};

subtest 'restart: runs ubic_restart then port_check' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = TestService->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    my $r = $svc_mgr->restart('demo.web');
    my @steps = map { $_->{step} } @{ $r->{data}{steps} };
    is_deeply \@steps, [qw(ubic_restart port_check)],
        'restart emits only ubic_restart + port_check';
};

done_testing;
