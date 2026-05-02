use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Mojo::Log;
use Deploy::Config;
use Deploy::Service;

# Fake transport that returns a canned `ubic status` listing.
{
    package FakeTransport;
    use Mojo::Base -base, -signatures;
    has 'ubic_output' => '';
    sub run ($self, $cmd, %_o) {
        return { ok => 1, output => $self->ubic_output } if $cmd =~ /^ubic status/;
        return { ok => 0, output => '' };
    }
    sub run_in_dir ($self, $dir, $cmd, %_o) { return { ok => 0, output => '' } }
}

my $home = tempdir(CLEANUP => 1);
my $scan = tempdir(CLEANUP => 1);

# Two services: dev-only and dev+live.
for my $entry (
    [ 'web.devonly.do', "name: dev.only\nentry: bin/x.pl\nrunner: morbo\ndev:\n  host: localhost\n  port: 4001\n" ],
    [ 'web.both.do',    "name: both.web\nentry: bin/x.pl\nrunner: hypnotoad\ndev:\n  host: localhost\n  port: 4002\nlive:\n  host: both.do\n  port: 4002\n" ],
) {
    my ($dir, $yml) = @$entry;
    my $repo = path($scan, $dir);
    $repo->mkpath;
    path($repo, '321.yml')->spew_utf8($yml);
}

my $cfg = Deploy::Config->new(app_home => "$home", scan_dir => "$scan", target => 'live');
my $tx  = FakeTransport->new(ubic_output => "    both.web\trunning (pid 1234)\n");

subtest 'filter_to_local off: shows all services regardless of ubic state' => sub {
    my $svc_mgr = Deploy::Service->new(
        config => $cfg, log => Mojo::Log->new(level => 'fatal'),
        transport => $tx, filter_to_local => 0,
    );
    my $rows = $svc_mgr->all_status;
    my @names = sort map { $_->{name} } @$rows;
    is_deeply \@names, [ 'both.web', 'dev.only' ], 'both services listed';
};

subtest 'filter_to_local on: hides services not in local ubic' => sub {
    my $svc_mgr = Deploy::Service->new(
        config => $cfg, log => Mojo::Log->new(level => 'fatal'),
        transport => $tx, filter_to_local => 1,
    );
    my $rows = $svc_mgr->all_status;
    my @names = sort map { $_->{name} } @$rows;
    is_deeply \@names, [ 'both.web' ], 'dev-only filtered out';
};

done_testing;
