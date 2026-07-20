use strict;
use warnings;
use Test::More;
use Deploy::GoBin;

my $ARCHES = { 'linux/amd64' => { url => 'u', sha256 => 's', sig => 'g' } };

subtest 'add_build sets builds, latest, min_supported' => sub {
    my $g = Deploy::GoBin->new;
    my $m = Deploy::GoBin::empty_manifest('123');
    $g->manifest_add_build($m, version => '1.0.0', arches => $ARCHES, min_supported => '0.9.0');
    is $m->{latest}, '1.0.0', 'latest';
    is $m->{min_supported}, '0.9.0', 'min_supported';
    is_deeply $m->{builds}{'1.0.0'}, $ARCHES, 'per-arch stored';
};

subtest 'prune keeps the N highest and never drops latest' => sub {
    my $g = Deploy::GoBin->new;
    my $m = Deploy::GoBin::empty_manifest('123');
    for my $v (qw(1.0.0 1.1.0 1.2.0 1.3.0)) {
        $g->manifest_add_build($m, version => $v, arches => $ARCHES, min_supported => '1.0.0');
    }
    $g->manifest_prune($m, 2);
    is_deeply [sort keys %{ $m->{builds} }], ['1.2.0', '1.3.0'], 'two newest kept';
    is $m->{latest}, '1.3.0', 'latest intact';
};

subtest 'rollback re-points latest to the previous build' => sub {
    my $g = Deploy::GoBin->new;
    my $m = Deploy::GoBin::empty_manifest('123');
    $g->manifest_add_build($m, version => $_, arches => $ARCHES, min_supported => '1.0.0')
        for qw(1.0.0 1.1.0 1.2.0);
    my ($m2, $prev) = $g->manifest_rollback($m);
    is $prev, '1.1.0', 'previous version returned';
    is $m2->{latest}, '1.1.0', 'latest re-pointed';
};

subtest 'rollback refuses when there is no prior build' => sub {
    my $g = Deploy::GoBin->new;
    my $m = Deploy::GoBin::empty_manifest('123');
    $g->manifest_add_build($m, version => '1.0.0', arches => $ARCHES, min_supported => '1.0.0');
    eval { $g->manifest_rollback($m) };
    like $@, qr/no prior|previous/i, 'dies with a clear message';
};

done_testing;
