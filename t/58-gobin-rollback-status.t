use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Log;
use Deploy::GoBin;

package FakeS3 {
    use Path::Tiny qw(path);
    sub new { my ($c, %a) = @_; bless { store => { %{ $a{store} // {} } }, puts => [] }, $c }
    sub put {
        my ($s, %a) = @_;
        push @{ $s->{puts} }, $a{key};
        $s->{store}{ $a{key} } = defined $a{file} ? path($a{file})->slurp_raw : $a{content};
        return { ok => 1 };
    }
    sub get {
        my ($s, %a) = @_;
        return exists $s->{store}{ $a{key} }
            ? { ok => 1, content => $s->{store}{ $a{key} } } : { ok => 0 };
    }
    sub head { my ($s, %a) = @_; return { ok => (exists $s->{store}{ $a{key} } ? 1 : 0) } }
}

package main;

sub gobin_with {
    my ($repo, $s3) = @_;
    return Deploy::GoBin->new(
        repo => "$repo",
        gobin => { name => '123', s3 => { bucket => 'b', prefix => 'bin/123' }, retain => 5 },
        secrets => {}, s3 => $s3, log => Mojo::Log->new(level => 'fatal'),
    );
}

my $ARCHES = { 'linux/amd64' => { url => 'u', sha256 => 's', sig => 'g' } };

sub seeded_s3 {
    my $g = Deploy::GoBin->new(gobin => { name => '123' });
    my $m = Deploy::GoBin::empty_manifest('123');
    $g->manifest_add_build($m, version => $_, arches => $ARCHES, min_supported => '1.0.0')
        for qw(1.4.0 1.5.0);
    return FakeS3->new(store => { 'bin/123/version.json' => encode_json($m) });
}

subtest 'rollback re-points latest to the previous build and writes it' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $s3 = seeded_s3();
    my ($prev) = gobin_with($tmp, $s3)->rollback;
    is $prev, '1.4.0', 'previous returned';
    my $m = decode_json($s3->get(key => 'bin/123/version.json')->{content});
    is $m->{latest}, '1.4.0', 'manifest latest re-pointed and persisted';
};

subtest 'rollback refuses with a single build (no write)' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $g1 = Deploy::GoBin->new(gobin => { name => '123' });
    my $m = Deploy::GoBin::empty_manifest('123');
    $g1->manifest_add_build($m, version => '1.0.0', arches => $ARCHES, min_supported => '1.0.0');
    my $s3 = FakeS3->new(store => { 'bin/123/version.json' => encode_json($m) });
    eval { gobin_with($tmp, $s3)->rollback };
    like $@, qr/no prior|previous/i, 'refused';
    is scalar @{ $s3->{puts} }, 0, 'nothing written';
};

subtest 'rollback refuses when there is no live manifest' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $s3 = FakeS3->new;
    eval { gobin_with($tmp, $s3)->rollback };
    like $@, qr/no live manifest/i, 'refused with a clear message';
};

subtest 'status compares built dist against live latest' => sub {
    my $repo = tempdir(CLEANUP => 1);
    path($repo, 'dist')->mkpath;
    path($repo, 'dist', 'gobin-meta.json')->spew_utf8(encode_json({
        version => '1.5.0', min_supported => '1.4.0',
        checksums => { 'linux/amd64' => 'a', 'darwin/arm64' => 'b' } }));
    my $rep = gobin_with($repo, seeded_s3())->status;
    is $rep->{built}, '1.5.0', 'built version';
    is $rep->{live},  '1.5.0', 'live latest';
    ok $rep->{arches}{'linux/amd64'}{built}, 'arch built locally';
    ok $rep->{arches}{'linux/amd64'}{live},  'arch live';
    ok $rep->{arches}{'darwin/arm64'}{built}, 'second arch built';
    ok !$rep->{arches}{'darwin/arm64'}{live}, 'second arch not in live build';
};

subtest 'status with nothing built and no manifest' => sub {
    my $repo = tempdir(CLEANUP => 1);
    my $rep = gobin_with($repo, FakeS3->new)->status;
    is $rep->{built}, undef, 'no built version';
    is $rep->{live},  undef, 'no live version';
    is_deeply $rep->{arches}, {}, 'no arches';
};

done_testing;
