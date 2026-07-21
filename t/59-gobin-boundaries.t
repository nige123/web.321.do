use strict;
use warnings;
use Test::More;
use Deploy::GoBin::S3;
use Deploy::GoBin::Runner;

subtest 'S3 put builds an aws s3api command with creds in env, not argv' => sub {
    my @calls;
    my $s3 = Deploy::GoBin::S3->new(
        bucket => '123do-releases',
        creds  => { s3_access_key_id => 'AKIA', s3_secret_access_key => 'SECRET' },
        exec   => sub { my (%a) = @_; push @calls, \%a; return { ok => 1, output => '' } },
    );
    my $r = $s3->put(key => 'bin/123/1.5.0/x.tar.gz', file => '/tmp/x.tar.gz',
                     content_type => 'application/gzip');
    is $r->{ok}, 1, 'put ok';
    my $c = $calls[0];
    like $c->{cmd}, qr/aws s3api put-object/, 'put-object verb';
    like $c->{cmd}, qr/--bucket 123do-releases/, 'bucket';
    like $c->{cmd}, qr{--key bin/123/1\.5\.0/x\.tar\.gz}, 'key';
    like $c->{cmd}, qr{--body /tmp/x\.tar\.gz}, 'body file';
    like $c->{cmd}, qr{--content-type application/gzip}, 'content type';
    unlike $c->{cmd}, qr/AKIA|SECRET/, 'creds never on the command line';
    is $c->{env}{AWS_ACCESS_KEY_ID},     'AKIA',   'access key in env';
    is $c->{env}{AWS_SECRET_ACCESS_KEY}, 'SECRET', 'secret in env';
};

subtest 'S3 put with inline content writes a temp body file' => sub {
    my @calls;
    my $s3 = Deploy::GoBin::S3->new(
        bucket => 'b', creds => {},
        exec => sub { my (%a) = @_; push @calls, \%a; return { ok => 1, output => '' } },
    );
    $s3->put(key => 'version.json', content => '{"latest":"1.0.0"}',
             content_type => 'application/json');
    my ($body) = $calls[0]{cmd} =~ /--body (\S+)/;
    ok $body, 'a body path was passed';
    unlike $calls[0]{cmd}, qr/latest/, 'content itself not on the command line';
};

subtest 'S3 head maps exit to ok' => sub {
    my $s3_hit = Deploy::GoBin::S3->new(bucket => 'b', creds => {},
        exec => sub { { ok => 1, output => '{}' } });
    is $s3_hit->head(key => 'present')->{ok}, 1, 'present object -> ok';
    my $s3_miss = Deploy::GoBin::S3->new(bucket => 'b', creds => {},
        exec => sub { { ok => 0, output => 'Not Found' } });
    is $s3_miss->head(key => 'missing')->{ok}, 0, 'absent object -> not ok';
};

subtest 'S3 get returns undef content on a miss' => sub {
    my $s3 = Deploy::GoBin::S3->new(bucket => 'b', creds => {},
        exec => sub { { ok => 0, output => 'NoSuchKey' } });
    my $r = $s3->get(key => 'missing');
    is $r->{ok}, 0, 'not ok';
    is $r->{content}, undef, 'no content';
};

subtest 'Runner builds the goreleaser command in the repo dir' => sub {
    my @calls;
    my $r = Deploy::GoBin::Runner->new(
        exec => sub { my (%a) = @_; push @calls, \%a; return { ok => 1, output => '' } });
    $r->run(dir => '/home/s3/tui.123.do', config => '/tmp/gr.yaml',
            env => { CGO_ENABLED => 0, GOBIN_SIGNING_KEY => 'SEKRITKEY' });
    my $c = $calls[0];
    like $c->{cmd}, qr{goreleaser release --clean -f /tmp/gr\.yaml}, 'release with config';
    is $c->{dir}, '/home/s3/tui.123.do', 'runs in the repo';
    is $c->{env}{CGO_ENABLED}, 0, 'CGO env passed';
    is $c->{env}{GOBIN_SIGNING_KEY}, 'SEKRITKEY', 'signing key in env';
    unlike $c->{cmd}, qr/SEKRITKEY/, 'signing key not on the command line';
};

done_testing;
