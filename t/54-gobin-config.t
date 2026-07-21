use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use YAML::XS qw(Load);
use Deploy::GoBin;

my %BLOCK = (
    name => '123', main => '.', version_var => 'main.version',
    s3 => { bucket => '123do-releases', prefix => 'bin/123' },
    sign_key => 'gobin_signing_key', retain => 5,
);

subtest 'generated config carries the required build knobs' => sub {
    my $g = Deploy::GoBin->new(gobin => { %BLOCK });
    my $doc = Load($g->goreleaser_yaml('1.5.0'));
    my $b = $doc->{builds}[0];
    is $b->{main},   '.',   'main package';
    is $b->{binary}, '123', 'binary name';
    ok +(grep { $_ eq 'CGO_ENABLED=0' } @{ $b->{env} }), 'CGO disabled';
    ok +(grep { /-X main\.version=1\.5\.0/ } @{ $b->{ldflags} }), 'version stamped via ldflags';
    is_deeply [sort @{ $b->{goos} }],   [sort qw(linux darwin windows)], 'default OSes';
    is_deeply [sort @{ $b->{goarch} }], [sort qw(amd64 arm64)],          'default arches';
    is $doc->{checksum}{name_template}, 'SHA256SUMS', 'checksum file name';
    ok $doc->{signs}, 'a signs block exists';
    is $doc->{signs}[0]{cmd}, 'gobin-sign', 'signs calls the ed25519 shim';
    # GoReleaser scrubs the sign-hook env; a bare name forwards it through.
    ok +(grep { $_ eq 'GOBIN_SIGNING_KEY' } @{ $doc->{signs}[0]{env} }),
        'signs block forwards GOBIN_SIGNING_KEY into the scrubbed hook env';
};

subtest 'explicit targets narrow the matrix' => sub {
    my $g = Deploy::GoBin->new(gobin => { %BLOCK, targets => ['linux/amd64'] });
    my $doc = Load($g->goreleaser_yaml('1.5.0'));
    is_deeply $doc->{builds}[0]{goos},   ['linux'], 'only linux';
    is_deeply $doc->{builds}[0]{goarch}, ['amd64'], 'only amd64';
};

subtest 'a checked-in .goreleaser.yaml overrides generation' => sub {
    my $dir = tempdir(CLEANUP => 1);
    path($dir, '.goreleaser.yaml')->spew_utf8("project_name: hand-written\n");
    my $g = Deploy::GoBin->new(gobin => { %BLOCK });
    my ($path, $generated) = $g->resolve_config_path('1.5.0', dir => "$dir");
    is $path, path($dir, '.goreleaser.yaml')->stringify, 'uses the checked-in file';
    is $generated, 0, 'not generated';

    my $dir2 = tempdir(CLEANUP => 1);
    my ($p2, $gen2) = $g->resolve_config_path('1.5.0', dir => "$dir2");
    is $p2, path($dir2, '.goreleaser.generated.yaml')->stringify, 'writes generated file';
    is $gen2, 1, 'generated';
    ok path($p2)->exists, 'generated file on disk';
};

done_testing;
