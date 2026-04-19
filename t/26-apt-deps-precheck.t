use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Config;
use Deploy::Service;
use Mojo::Log;

my $home = tempdir(CLEANUP => 1);
path($home, 'services')->mkpath;
path($home, 'secrets')->mkpath;
my $repo = tempdir(CLEANUP => 1);

my $svc_mgr = Deploy::Service->new(
    config => Deploy::Config->new(app_home => $home, target => 'live'),
    log    => Mojo::Log->new(level => 'fatal'),
);

subtest 'no apt_deps declared → pass' => sub {
    my $svc = { apt_deps => [] };
    my ($ok, $out) = $svc_mgr->_check_apt_deps($svc);
    ok $ok,                      'check passes with empty list';
    like $out, qr/no apt_deps/i, 'message says none declared';
};

subtest 'undef apt_deps → pass' => sub {
    my ($ok, $out) = $svc_mgr->_check_apt_deps({});
    ok $ok, 'check passes when field absent';
};

subtest 'declared & installed → pass' => sub {
    # coreutils is always installed on linux
    my $svc = { apt_deps => ['coreutils'] };
    my ($ok, $out) = $svc_mgr->_check_apt_deps($svc);
    ok $ok,                         'check passes';
    like $out, qr/all installed/,   'message confirms';
    like $out, qr/coreutils/,       'lists the package';
};

subtest 'declared but missing → auto-install fails for bogus package' => sub {
    my $bogus = 'nonexistent-package-xyz-' . time;
    my $svc = { apt_deps => ['coreutils', $bogus] };
    my ($ok, $out) = $svc_mgr->_check_apt_deps($svc);
    ok !$ok,                       'check fails when install fails';
    like $out, qr/\Q$bogus\E/,     'names the missing package';
};

done_testing;
