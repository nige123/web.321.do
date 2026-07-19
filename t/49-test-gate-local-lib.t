use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Local;
use Deploy::Command::go;
use Deploy::Command::test;

# The manifest test: command must run with the repo's bundled local-lib -
# PERL5LIB=<repo>/local/lib/perl5 and <repo>/local/bin on PATH - the same env
# every other 321 execution path (deploy steps, ubic files, `321 do`) already
# exports. A bare `test: prove -lr t` would otherwise run against ambient
# site_perl: the pre-live gate then fails wrongly, or worse quietly passes
# against deps the deploy doesn't ship. Covers the shared builder and both
# consumers: the `321 go` live gate and `321 test`.

sub make_fixture {
    my $home_obj = tempdir(CLEANUP => 1);
    my $scan_obj = tempdir(CLEANUP => 1);
    my $repo = path($scan_obj, 'web.demo.do');
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
test: prove -lr t
dev:
  host: demo.do.dev
  port: 39500
  runner: morbo
live:
  host: demo.do
  port: 39500
  runner: hypnotoad
YAML
    return ("$home_obj", "$scan_obj", "$repo", $home_obj, $scan_obj);
}

sub make_app {
    my ($cfg) = @_;
    require Mojolicious;
    my $app = Mojolicious->new;
    $app->attr(config_obj => sub { $cfg });
    return $app;
}

# go must never reach transport work when the gate is red.
package TestGo {
    use parent -norequire, 'Deploy::Command::go';
    sub transport_for { die "deploy proceeded past a red test gate" }
}

# Recording transport for `321 test` - only stream() is needed.
package StreamTransport {
    sub new { bless { calls => [] }, shift }
    sub stream { my ($self, $cmd) = @_; push @{ $self->{calls} }, $cmd; return { ok => 1, output => '' } }
    sub calls { @{ $_[0]{calls} } }
}

package TestTest {
    use parent -norequire, 'Deploy::Command::test';
    our $TRANSPORT;
    sub transport_for { $TRANSPORT }
}

package main;

subtest 'test_command pins PERL5LIB + PATH to the repo local-lib' => sub {
    my ($home, $scan, $repo, $home_obj, $scan_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'live');
    my $app = make_app($cfg);   # command's app attr is weak - keep a real ref
    my $cmd = Deploy::Command->new(app => $app);
    my $svc = $cfg->service('demo.web');
    is $cmd->test_command($svc),
       "cd $repo && PERL5LIB=$repo/local/lib/perl5 PATH=$repo/local/bin:\$PATH prove -lr t",
       'cd repo, repo local-lib on PERL5LIB, repo bin on PATH, then the manifest command';
};

subtest '321 go live: gate streams the pinned command, red aborts the deploy' => sub {
    my ($home, $scan, $repo, $home_obj, $scan_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'dev');
    my $app = make_app($cfg);
    my $cmd = TestGo->new(app => $app);
    my @streamed;
    no warnings 'redefine';
    local *Deploy::Local::stream = sub {
        my ($self, $shell) = @_;
        push @streamed, $shell;
        return { ok => 0, output => '' };
    };
    my $lived = eval { $cmd->run('demo.web', 'live'); 1 };
    ok $lived, 'red gate returns instead of deploying' or diag $@;
    is scalar @streamed, 1, 'exactly one gate invocation';
    like $streamed[0], qr{PERL5LIB=\Q$repo\E/local/lib/perl5},
        'gate command carries the repo local-lib';
};

subtest '321 test runs the same pinned command through the transport' => sub {
    my ($home, $scan, $repo, $home_obj, $scan_obj) = make_fixture();
    my $cfg = Deploy::Config->new(app_home => $home, scan_dir => $scan, target => 'dev');
    my $t = StreamTransport->new;
    local $TestTest::TRANSPORT = $t;
    my $app = make_app($cfg);
    my $cmd = TestTest->new(app => $app);
    is $cmd->_test_one('demo.web', 'dev'), 0, 'green suite reports success';
    my ($streamed) = $t->calls;
    is $streamed,
       "cd $repo && PERL5LIB=$repo/local/lib/perl5 PATH=$repo/local/bin:\$PATH prove -lr t",
       'same builder, same pinned env';
};

done_testing;
