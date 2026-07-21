use strict;
use warnings;
use Test::More;
use Path::Tiny qw(tempdir path);

# bin/gobin-sign <artifact> - the signer the generated .goreleaser.yaml's
# signs block invokes per artifact. The ed25519 private key arrives ONLY via
# $GOBIN_SIGNING_KEY (PEM in the environment - never argv, never a file the
# caller manages) and the output is <artifact>.sig, a raw signature the 123
# self-updater verifies against its embedded public key.

my $tmp = tempdir(CLEANUP => 1);
my $sk  = path($tmp, 'sk.pem');
my $pk  = path($tmp, 'pk.pem');

plan skip_all => 'openssl with ed25519 support not available'
    if system("openssl genpkey -algorithm ed25519 -out $sk 2>/dev/null") != 0;
system("openssl pkey -in $sk -pubout -out $pk 2>/dev/null") == 0
    or BAIL_OUT('could not derive public key');

my $artifact = path($tmp, '123_linux_amd64.tar.gz');
$artifact->spew_raw('pretend artifact bytes');

subtest 'signs an artifact from the env key' => sub {
    local $ENV{GOBIN_SIGNING_KEY} = $sk->slurp;
    is system('bin/gobin-sign', "$artifact"), 0, 'exit 0';
    ok -s "$artifact.sig", 'wrote a non-empty <artifact>.sig';
    is system("openssl pkeyutl -verify -pubin -inkey $pk -rawin"
            . " -in $artifact -sigfile $artifact.sig >/dev/null 2>&1"), 0,
        'signature verifies against the matching public key';
};

subtest 'a tampered artifact fails verification' => sub {
    $artifact->append_raw('!');
    isnt system("openssl pkeyutl -verify -pubin -inkey $pk -rawin"
              . " -in $artifact -sigfile $artifact.sig >/dev/null 2>&1"), 0,
        'verification rejects modified bytes';
};

subtest 'refuses without a key in the environment' => sub {
    local $ENV{GOBIN_SIGNING_KEY};
    delete $ENV{GOBIN_SIGNING_KEY};
    isnt system("bin/gobin-sign $artifact 2>/dev/null"), 0, 'non-zero exit';
};

done_testing;
