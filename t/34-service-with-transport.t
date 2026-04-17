use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Deploy::Local;
use Mojo::Log;

# Build a minimal fixture: a temp app_home + a git repo with cpanfile
sub make_fixture {
    my $home = tempdir(CLEANUP => 1);
    path($home, 'services')->mkpath;
    path($home, 'secrets')->mkpath;

    my $repo = tempdir(CLEANUP => 1);
    system("cd $repo && git init -q && git config user.email t\@t && git config user.name t && git commit --allow-empty -m init -q");
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

# 1. Service accepts transport attribute (isa Deploy::Local)
subtest 'Service accepts transport attribute' => sub {
    my ($home) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'live'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );
    isa_ok $svc_mgr->transport, 'Deploy::Local', 'transport attribute';
};

# 2. Default transport is Deploy::Local->new
subtest 'Default transport is Deploy::Local' => sub {
    my ($home) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config => Deploy::Config->new(app_home => $home, target => 'live'),
        log    => Mojo::Log->new(level => 'fatal'),
    );
    isa_ok $svc_mgr->transport, 'Deploy::Local', 'default transport is Deploy::Local';
};

# 3. Deploy uses transport — gets through apt_deps step at minimum
subtest 'Deploy uses transport - passes apt_deps step' => sub {
    my ($home, $repo) = make_fixture();

    # Subclass to stub out expensive steps after apt_deps
    package StubTransportService;
    use parent -norequire, 'Deploy::Service';
    # Stub ubic restart via transport: override _step_ubic_restart
    sub _step_ubic_restart { return { step => 'ubic_restart', success => \1, output => 'stubbed' } }
    sub _check_port         { return 1 }

    package main;

    my $svc_mgr = StubTransportService->new(
        config    => Deploy::Config->new(app_home => $home, target => 'live'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );

    my $r = $svc_mgr->deploy('demo.web', skip_git => 1);

    # We expect at least an apt_deps step in results
    my @step_names = map { $_->{step} } @{ $r->{data}{steps} };
    ok grep({ $_ eq 'apt_deps' } @step_names), 'apt_deps step present in deploy result';

    my ($apt_step) = grep { $_->{step} eq 'apt_deps' } @{ $r->{data}{steps} };
    ok $apt_step, 'apt_deps step found';
    ok ${ $apt_step->{success} }, 'apt_deps step succeeded (no apt_deps declared)';
};

# 4. Status uses transport for git sha — returns valid hex sha
subtest 'Status uses transport for git sha' => sub {
    my ($home, $repo) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'live'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );

    my $sha = $svc_mgr->_git_sha($repo);
    ok defined $sha, 'git sha is defined';
    like $sha, qr/^[0-9a-f]{7,}$/, "git sha looks like a hex string: $sha";
};

# 5. _run_in_dir delegates to transport and returns hashref
subtest '_run_in_dir returns hashref from transport' => sub {
    my ($home) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'live'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );

    my $r = $svc_mgr->_run_in_dir('/tmp', 'echo hello_from_transport');
    ok ref($r) eq 'HASH', '_run_in_dir returns a hashref';
    ok $r->{ok}, '_run_in_dir ok flag is set';
    like $r->{output}, qr/hello_from_transport/, '_run_in_dir output contains expected text';
};

# 6. _run_cmd delegates to transport and returns hashref
subtest '_run_cmd returns hashref from transport' => sub {
    my ($home) = make_fixture();
    my $svc_mgr = Deploy::Service->new(
        config    => Deploy::Config->new(app_home => $home, target => 'live'),
        log       => Mojo::Log->new(level => 'fatal'),
        transport => Deploy::Local->new,
    );

    my $r = $svc_mgr->_run_cmd('echo hello_cmd');
    ok ref($r) eq 'HASH', '_run_cmd returns a hashref';
    ok $r->{ok}, '_run_cmd ok flag is set';
    like $r->{output}, qr/hello_cmd/, '_run_cmd output contains expected text';
};

done_testing;
