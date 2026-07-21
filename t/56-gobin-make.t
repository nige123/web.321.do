use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);
use Mojo::JSON qw(decode_json);
use Mojo::Log;
use Deploy::GoBin;

# Fake GoReleaser runner: records every run() call.
my @RUN;
package FakeRunner {
    sub new { bless {}, shift }
    sub run { my ($s, %a) = @_; push @RUN, \%a; return { ok => 1, output => '' } }
}
my $runner = FakeRunner->new;

# Returns ($gobin, $repo_obj, $git_coderef, \@gitlog). Hold $repo_obj in the
# caller so CLEANUP does not delete the dir before make() writes to it.
sub make_gobin {
    my (%over) = @_;
    my $repo = tempdir(CLEANUP => 1);
    my $dist = path($repo, 'dist'); $dist->mkpath;
    # goreleaser would write these; we prewrite so meta reflects a real run.
    path($dist, 'SHA256SUMS')->spew_utf8(
        "aaaa  123_linux_amd64.tar.gz\nbbbb  123_darwin_arm64.tar.gz\n");
    my @git;
    my $git = sub {
        my ($cmd) = @_;
        push @git, $cmd;
        return { ok => 1, output => " M x\n" } if $cmd =~ /status --porcelain/ && $over{dirty};
        return { ok => 1, output => '' };
    };
    my $g = Deploy::GoBin->new(
        repo    => "$repo",
        gobin   => { name => '123', main => '.', version_var => 'main.version',
                     s3 => { bucket => 'b', prefix => 'p' }, sign_key => 'gobin_signing_key' },
        secrets => { gobin_signing_key => 'PRIVKEY' },
        runner  => $runner,
        log     => Mojo::Log->new(level => 'fatal'),
    );
    return ($g, $repo, $git, \@git);
}

subtest 'happy make: preflight passes, tags, runs, writes meta' => sub {
    @RUN = ();
    my ($g, $repo, $git, $gitlog) = make_gobin();
    my $r = $g->make(latest => '1.4.0', bump => 'minor', git => $git, which => sub { 1 });
    is $r->{version}, '1.5.0', 'version resolved';
    ok +(grep { /tag -a v1\.5\.0/ } @$gitlog), 'annotated tag created';
    ok +(grep { /push origin v1\.5\.0/ } @$gitlog), 'tag pushed';
    is scalar @RUN, 1, 'runner invoked once';
    ok $RUN[0]{config}, 'runner got a config path';

    my $meta = decode_json(path($repo, 'dist', 'gobin-meta.json')->slurp_utf8);
    is $meta->{version}, '1.5.0', 'meta version';
    is $meta->{min_supported}, '1.4.0', 'min_supported defaults to previous latest';
    is $meta->{checksums}{'linux/amd64'},  'aaaa', 'checksum mapped by os/arch';
    is $meta->{checksums}{'darwin/arm64'}, 'bbbb', 'second checksum';
};

subtest 'dirty tree aborts before tagging' => sub {
    @RUN = ();
    my ($g, $repo, $git, $gitlog) = make_gobin(dirty => 1);
    eval { $g->make(latest => '1.4.0', bump => 'patch', git => $git, which => sub { 1 }) };
    like $@, qr/clean|uncommitted/i, 'preflight message';
    ok !(grep { /tag -a/ } @$gitlog), 'no tag was created';
    is scalar @RUN, 0, 'runner never called';
};

subtest 'missing toolchain aborts' => sub {
    my ($g, $repo, $git) = make_gobin();
    eval { $g->make(latest => '1.4.0', bump => 'patch', git => $git,
                    which => sub { $_[0] eq 'go' ? 1 : 0 }) };
    like $@, qr/goreleaser/i, 'goreleaser-on-PATH check fires';
};

subtest 'missing signing key aborts' => sub {
    my $repo = tempdir(CLEANUP => 1);
    path($repo, 'dist')->mkpath;
    my $g = Deploy::GoBin->new(
        repo => "$repo",
        gobin => { name => '123', version_var => 'main.version', sign_key => 'gobin_signing_key',
                   s3 => { bucket => 'b', prefix => 'p' } },
        secrets => {},   # key absent
        runner => $runner, log => Mojo::Log->new(level => 'fatal'),
    );
    eval { $g->make(latest => '1.4.0', bump => 'patch',
                    git => sub { { ok => 1, output => '' } }, which => sub { 1 }) };
    like $@, qr/sign|key/i, 'signing-key preflight fires';
};

done_testing;
