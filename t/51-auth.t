use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::File;
use Mojo::Util qw(b64_encode);

# Basic Auth is enforced in production and skipped in development; /health is
# always public. This pins the production auth boundary that commit b0596a6
# stripped while CLAUDE.md still promised it. Mutation check: delete the
# `under '/'` hook in bin/321.pl and the 401 subtests below go red.
#
# Each Test::Mojo->new reloads the app, so MOJO_MODE / DEPLOY_AUTH set just
# before construction take effect for that instance.

my $APP = 'bin/321.pl';

subtest 'development mode: open, no credentials needed' => sub {
    local $ENV{MOJO_MODE} = 'development';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    $t->get_ok('/services')->status_is(200);
    $t->get_ok('/health')->status_is(200);
};

subtest 'production: protected routes 401 without credentials' => sub {
    local $ENV{MOJO_MODE} = 'production';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    $t->get_ok('/services')->status_is(401)
      ->header_like('WWW-Authenticate' => qr/Basic realm="321\.do"/);
    $t->get_ok('/git/status')->status_is(401);
};

subtest 'production: /health is always public' => sub {
    local $ENV{MOJO_MODE} = 'production';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    $t->get_ok('/health')->status_is(200);
};

subtest 'production: correct Basic credentials authenticate' => sub {
    local $ENV{MOJO_MODE} = 'production';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    my $cred = 'Basic ' . b64_encode('321:kaizen', '');
    $t->get_ok('/services' => { Authorization => $cred })->status_is(200);
};

subtest 'production: wrong credentials rejected' => sub {
    local $ENV{MOJO_MODE} = 'production';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    my $cred = 'Basic ' . b64_encode('321:nope', '');
    $t->get_ok('/services' => { Authorization => $cred })->status_is(401);
};

subtest 'production: DEPLOY_AUTH overrides the default secret' => sub {
    local $ENV{MOJO_MODE}   = 'production';
    local $ENV{DEPLOY_AUTH} = 'admin:s3cr3t';
    my $t = Test::Mojo->new(Mojo::File->new($APP));
    $t->get_ok('/services' => { Authorization => 'Basic ' . b64_encode('admin:s3cr3t', '') })
      ->status_is(200);
    $t->get_ok('/services' => { Authorization => 'Basic ' . b64_encode('321:kaizen', '') })
      ->status_is(401);
};

done_testing;
