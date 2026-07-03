use strict;
use warnings;

BEGIN {
    $ENV{MOJO_MODE}      ||= 'testing';
    $ENV{MOJO_CONFIG}    ||= 't/conf/test.conf';
    $ENV{MOJO_LOG_LEVEL} ||= 'warn';
}

use Test::Most;
use Test::Mojo;
use lib 'lib';

use_ok 'L2D::Web';

my $t = Test::Mojo->new('L2D::Web');
$t->get_ok('/health')->status_is(200)->content_is('ok');
$t->get_ok('/')->status_is(200);

done_testing;
