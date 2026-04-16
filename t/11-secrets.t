use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Deploy::Secrets;

my $home = tempdir(CLEANUP => 1);
path($home, 'secrets')->mkpath;

my $s = Deploy::Secrets->new(app_home => $home);

subtest 'diff: no file, nothing required' => sub {
    my $d = $s->diff('svc', { required => {}, optional => {} });
    is_deeply $d->{missing}, [];
    is_deeply $d->{present}, [];
};

subtest 'diff: missing required key' => sub {
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => {},
    });
    is_deeply [sort @{$d->{missing}}], [qw(API_KEY DB_URL)];
};

subtest 'set + diff: required present' => sub {
    $s->set('svc', 'API_KEY', 'abc123', actor => 'tester');
    $s->set('svc', 'DB_URL',  'postgres://', actor => 'tester');
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => { LOG_LEVEL => { default => 'info' } },
    });
    is_deeply $d->{missing}, [], 'nothing missing';
    is_deeply [sort @{$d->{present}}], [qw(API_KEY DB_URL)];
    is_deeply $d->{optional_set}, [], 'optional key not set';
};

subtest 'atomic write: permissions 0600' => sub {
    my $file = path($home, 'secrets', 'svc.env');
    my $mode = (stat $file)[2] & 07777;
    is $mode, 0600, 'env file is 0600';
};

subtest 'audit log: append on set' => sub {
    my $log = path($home, 'secrets', 'svc.audit.log');
    ok $log->exists, 'audit log exists';
    my @lines = $log->lines_utf8({ chomp => 1 });
    is scalar @lines, 2, 'one line per set';
    like $lines[0], qr/^\S+ tester set API_KEY$/, 'format: ts actor action key';
    unlike $lines[0], qr/abc123/, 'value never in log';
};

subtest 'delete + diff' => sub {
    $s->delete('svc', 'DB_URL', actor => 'tester');
    my $d = $s->diff('svc', {
        required => { API_KEY => 'x', DB_URL => 'y' },
        optional => {},
    });
    is_deeply $d->{missing}, ['DB_URL'];
    my @lines = path($home, 'secrets', 'svc.audit.log')->lines_utf8({ chomp => 1 });
    like $lines[-1], qr/^\S+ tester delete DB_URL$/;
};

subtest 'reject invalid key name' => sub {
    my $err = eval { $s->set('svc', 'lowercase', 'x', actor => 't'); 0 } || $@;
    like $err, qr/invalid key/;
};

subtest 'reject value with newline' => sub {
    my $err = eval { $s->set('svc', 'GOOD_KEY', "a\nb", actor => 't'); 0 } || $@;
    like $err, qr/newline not allowed/;
};

done_testing;
