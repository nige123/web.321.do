use strict;
use warnings;
use Test::More;
use Deploy::GoBin;

subtest 'bump_semver math' => sub {
    is Deploy::GoBin::bump_semver('1.4.2', 'patch'), '1.4.3', 'patch';
    is Deploy::GoBin::bump_semver('1.4.2', 'minor'), '1.5.0', 'minor resets patch';
    is Deploy::GoBin::bump_semver('1.4.2', 'major'), '2.0.0', 'major resets minor+patch';
    eval { Deploy::GoBin::bump_semver('1.4',   'patch') }; like $@, qr/semver/i, 'bad semver dies';
    eval { Deploy::GoBin::bump_semver('1.4.2', 'huge')  }; like $@, qr/bump/i,   'bad level dies';
};

subtest 'semver_cmp ordering' => sub {
    is Deploy::GoBin::semver_cmp('1.4.0', '1.4.0'),  0, 'equal';
    is Deploy::GoBin::semver_cmp('1.4.0', '1.3.9'),  1, 'greater';
    is Deploy::GoBin::semver_cmp('1.4.0', '1.10.0'),-1, 'numeric not lexical (4 < 10)';
};

subtest 'resolve_version: bump, explicit, and newer-than-latest guard' => sub {
    my $g = Deploy::GoBin->new;
    is $g->resolve_version(latest => '1.4.2', bump => 'minor'), '1.5.0', 'bump from latest';
    is $g->resolve_version(latest => undef,   bump => 'patch'), '0.0.1', 'no latest -> from 0.0.0';
    is $g->resolve_version(latest => '1.4.2', version => '2.0.0'), '2.0.0', 'explicit wins';
    eval { $g->resolve_version(latest => '1.4.2', version => '1.4.2') };
    like $@, qr/newer|greater/i, 'must be strictly newer than latest';
    eval { $g->resolve_version(latest => '1.4.2', version => '1.4.0') };
    like $@, qr/newer|greater/i, 'older is rejected';
};

done_testing;
