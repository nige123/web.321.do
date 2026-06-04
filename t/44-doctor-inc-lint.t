use strict;
use warnings;
use Test::More;
use Deploy::Command::doctor;

# `321 doctor` audits each service repo's bin scripts for the fragile
# @INC pattern: globbing every subdir of local/lib/perl5 onto @INC. That
# pulls namespace dirs like HTTP/ onto @INC, where HTTP/Config.pm shadows
# core Config and breaks `use Config` in File::Copy/Mojo::File. The pure
# scanner is scan_inc($text) -> [ { line, text }, ... ].

my $C = 'Deploy::Command::doctor';

subtest 'flags a bare glob over the whole local-lib tree' => sub {
    my $src = <<'PL';
use FindBin;
BEGIN {
    unshift @INC, "$FindBin::Bin/../lib";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";
    for my $arch (glob "$FindBin::Bin/../local/lib/perl5/*") {
        next unless -d $arch;
        unshift @INC, $arch;
    }
}
PL
    my $hits = $C->scan_inc($src);
    is scalar(@$hits), 1, 'one offending line';
    is $hits->[0]{line}, 5, 'correct line number';
    like $hits->[0]{text}, qr/glob/, 'captures the offending source';
};

subtest 'arch-restricted glob (*-linux*) is safe' => sub {
    my $src = <<'PL';
    for my $arch (glob "$FindBin::Bin/../local/lib/perl5/*-linux*") {
        unshift @INC, $arch if -d $arch;
    }
PL
    is_deeply $C->scan_inc($src), [], 'not flagged';
};

subtest 'archname-based resolution is safe' => sub {
    my $src = <<'PL';
    require Config;
    my $arch = "$FindBin::Bin/../local/lib/perl5/$Config::Config{archname}";
    unshift @INC, $arch if -d $arch;
PL
    is_deeply $C->scan_inc($src), [], 'not flagged';
};

subtest 'plain lib unshifts are safe' => sub {
    my $src = <<'PL';
    unshift @INC, "$FindBin::Bin/../lib";
    unshift @INC, "$FindBin::Bin/lib";
    unshift @INC, "$FindBin::Bin/../local/lib/perl5";
PL
    is_deeply $C->scan_inc($src), [], 'not flagged';
};

subtest 'multiple offenders report each line' => sub {
    my $src = <<'PL';
for my $a (glob "x/local/lib/perl5/*") { }
something else
my @d = glob "y/../local/lib/perl5/*";
PL
    my $hits = $C->scan_inc($src);
    is scalar(@$hits), 2, 'two offenders';
    is_deeply [ map { $_->{line} } @$hits ], [1, 3], 'line numbers';
};

subtest 'empty/undef input is safe' => sub {
    is_deeply $C->scan_inc(''),    [], 'empty';
    is_deeply $C->scan_inc(undef), [], 'undef';
};

done_testing;
