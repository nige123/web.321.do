use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Log;
use Deploy::GoBin;

# Fake S3: records puts; serves gets from an in-memory store keyed by S3 key.
package FakeS3 {
    use Path::Tiny qw(path);
    sub new { bless { store => {}, puts => [] }, shift }
    sub put {
        my ($s, %a) = @_;
        push @{ $s->{puts} }, $a{key};
        $s->{store}{ $a{key} } = defined $a{file} ? path($a{file})->slurp_raw : $a{content};
        return { ok => 1 };
    }
    sub get {
        my ($s, %a) = @_;
        return exists $s->{store}{ $a{key} }
            ? { ok => 1, content => $s->{store}{ $a{key} } }
            : { ok => 0, content => undef };
    }
    sub head { my ($s, %a) = @_; return { ok => (exists $s->{store}{ $a{key} } ? 1 : 0) } }
    sub keys_put { @{ $_[0]{puts} } }
}

package main;

# Returns the tempdir OBJECT so CLEANUP does not delete it mid-subtest.
sub built_repo {
    my (%o) = @_;
    my $repo = tempdir(CLEANUP => 1);
    my $dist = path($repo, 'dist'); $dist->mkpath;
    unless ($o{empty}) {
        for my $t (qw(linux_amd64 darwin_arm64)) {
            path($dist, "123_$t.tar.gz")->spew_raw("BIN-$t");
            path($dist, "123_$t.tar.gz.sig")->spew_raw("SIG-$t");
        }
        path($dist, 'gobin-meta.json')->spew_utf8(encode_json({
            version => '1.5.0', min_supported => '1.4.0',
            checksums => { 'linux/amd64' => 'aaaa', 'darwin/arm64' => 'bbbb' },
        }));
    }
    return $repo;
}

sub gobin_with {
    my ($repo, $s3) = @_;
    return Deploy::GoBin->new(
        repo  => "$repo",
        gobin => { name => '123', version_var => 'main.version', retain => 5,
                   s3 => { bucket => '123do-releases', prefix => 'bin/123' },
                   sign_key => 'gobin_signing_key' },
        secrets => { gobin_signing_key => 'K',
                     s3_access_key_id => 'A', s3_secret_access_key => 'S' },
        s3 => $s3, log => Mojo::Log->new(level => 'fatal'),
    );
}

subtest 'release uploads immutable keys, writes+prunes manifest, verifies' => sub {
    my $repo = built_repo();
    my $s3 = FakeS3->new;
    my $g = gobin_with($repo, $s3);
    my $r = $g->release;

    is $r->{version}, '1.5.0', 'version from meta';
    ok +(grep { $_ eq 'bin/123/1.5.0/123_linux_amd64.tar.gz' }     $s3->keys_put), 'artifact key immutable+scoped';
    ok +(grep { $_ eq 'bin/123/1.5.0/123_linux_amd64.tar.gz.sig' } $s3->keys_put), 'sig uploaded';
    ok +(grep { $_ eq 'bin/123/version.json' }                     $s3->keys_put), 'manifest written';

    my $m = decode_json($s3->get(key => 'bin/123/version.json')->{content});
    is $m->{latest}, '1.5.0', 'latest set';
    is $m->{min_supported}, '1.4.0', 'min_supported carried from meta';
    is $m->{builds}{'1.5.0'}{'linux/amd64'}{sha256}, 'aaaa', 'checksum in manifest';
    like $m->{builds}{'1.5.0'}{'linux/amd64'}{url}, qr{bin/123/1\.5\.0/123_linux_amd64\.tar\.gz}, 'url';
    ok $r->{verified}, 'verify step passed (HEADs resolved)';
};

subtest 'release errors clearly when nothing is built' => sub {
    my $repo = built_repo(empty => 1);
    my $g = gobin_with($repo, FakeS3->new);
    eval { $g->release(version => '9.9.9') };
    like $@, qr/nothing built for 9\.9\.9.*321 gobin make/is, 'clear guidance';
};

subtest 'release preserves prior builds in the manifest' => sub {
    my $repo = built_repo();
    my $s3 = FakeS3->new;
    # seed an existing manifest with an older build
    my $g0 = gobin_with($repo, $s3);
    my $seed = Deploy::GoBin::empty_manifest('123');
    $g0->manifest_add_build($seed, version => '1.4.0',
        arches => { 'linux/amd64' => { url => 'old', sha256 => 'x', sig => 'y' } },
        min_supported => '1.3.0');
    $s3->put(key => 'bin/123/version.json', content => encode_json($seed));

    gobin_with($repo, $s3)->release;
    my $m = decode_json($s3->get(key => 'bin/123/version.json')->{content});
    is_deeply [sort keys %{ $m->{builds} }], ['1.4.0', '1.5.0'], 'old + new retained';
    is $m->{latest}, '1.5.0', 'latest advanced';
};

done_testing;
