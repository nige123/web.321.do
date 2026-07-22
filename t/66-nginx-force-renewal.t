use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Command::nginx;

# `321 nginx` cert acquisition rules:
#   - --force ALWAYS attempts acquisition (operator explicitly asked).
#   - without --force, a valid cert outside the renewal window is left alone,
#     but an expired / expiring cert IS renewed (presence is not enough).

my $scan_obj = tempdir(CLEANUP => 1);
my $home_obj = tempdir(CLEANUP => 1);
my $repo = path($scan_obj, 'web.demo.do');
$repo->mkpath;
path($repo, '321.yml')->spew_utf8(<<'YAML');
name: demo.web
entry: bin/app.pl
runner: hypnotoad
live:
  host: demo.do
  port: 9400
  ssh: ubuntu@demo.do
YAML

package FakeProvider { sub new { bless {}, shift } sub pick { 'certbot' } }

package FakeNginx {
    sub new { my ($c, %a) = @_; bless { acquired => 0, %a }, $c }
    sub transport     { }
    sub status        { $_[0]{status} }
    sub probe_cert    { $_[0]{probe} }
    sub setup         { { status => 'ok', steps => [] } }
    sub cert_provider { FakeProvider->new }
    sub generate      { }
    sub reload        { { status => 'ok' } }
    sub acquire_cert  { $_[0]{acquired}++; return { status => 'ok', output => '', provider => 'certbot' } }
}

package TestNginxCmd {
    use parent -norequire, 'Deploy::Command::nginx';
    our $NGINX;
    sub nginx         { $NGINX }
    sub transport_for { 'dummy' }
}

package main;

sub run_nginx {
    my ($fake, @args) = @_;
    local $TestNginxCmd::NGINX = $fake;
    require Mojolicious;
    my $app = Mojolicious->new;
    my $cfg = Deploy::Config->new(app_home => "$home_obj", scan_dir => "$scan_obj", target => 'live');
    $app->attr(config_obj => sub { $cfg });
    my $cmd = TestNginxCmd->new(app => $app);
    open my $fh, '>', \my $buf;
    my $old = select $fh;
    eval { $cmd->run(@args) };
    select $old;
    return $fake->{acquired};
}

my $VALID   = { ok => 1, expired => 0, expiring => 0, days_remaining => 60 };
my $EXPIRED = { ok => 0, expired => 1, expiring => 0, days_remaining => -2 };
my $WIRED   = { config_exists => 1, enabled => 1, ssl => 1, provider => 'certbot', host => 'demo.do' };

subtest 'valid cert, no --force: not re-acquired' => sub {
    is run_nginx(FakeNginx->new(status => $WIRED, probe => $VALID), 'demo.web', 'live'),
        0, 'left alone';
};

subtest 'expired cert, no --force: renewed' => sub {
    is run_nginx(FakeNginx->new(status => $WIRED, probe => $EXPIRED), 'demo.web', 'live'),
        1, 'acquire attempted';
};

subtest '--force always attempts acquisition, even on a valid cert' => sub {
    is run_nginx(FakeNginx->new(status => $WIRED, probe => $VALID), 'demo.web', 'live', '--force'),
        1, 'force acquires regardless';
};

done_testing;
