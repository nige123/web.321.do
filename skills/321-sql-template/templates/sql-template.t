use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

# Headless test of the renderer - no database needed. Point `use` at your
# ported package. Covers the behaviours that break silently: repeated-bind
# ordering, missing-vs-unused binds, dynamic branches, and the \@ escape.

use Test::More;
use lib 'lib';
use F6::DB::SQL;

my $r = F6::DB::SQL->new;

subtest 'placeholder extraction' => sub {
    my ($sql, $bind) = $r->render('SELECT * FROM t WHERE id = [id]', { id => 7 });
    like $sql, qr/id = \?/,     '[id] becomes ?';
    is_deeply $bind, [7],       'one bind, right value';
};

subtest 'a repeated bind binds each time, in textual order' => sub {
    my ($sql, $bind) = $r->render('SELECT [a], [b], [a] FROM t', { a => 1, b => 2 });
    is $sql =~ tr/?//, 3,       'three placeholders';
    is_deeply $bind, [1, 2, 1], 'value pushed per occurrence, in order';
};

subtest 'a missing bind dies' => sub {
    eval { $r->render('WHERE x = [nope]', {}) };
    like $@, qr/Missing bind parameter \[nope\]/, 'hard error on unknown [name]';
};

subtest 'an unused (defined) bind warns' => sub {
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, "@_" };
    $r->render('SELECT 1', { spare => 'x' });
    like "@warn", qr/unused bind parameter \[spare\]/, 'soft nudge on leftover key';
};

subtest 'Mojo::Template branch is included only when the var is defined' => sub {
    my $tmpl = "SELECT 1\n% if (defined \$tile_id) {\n AND tile_id = [tile_id]\n% }";
    my ($with)    = $r->render($tmpl, { tile_id => 9 });
    like   $with,    qr/tile_id = \?/, 'clause present when defined';
    my ($without) = $r->render($tmpl, { tile_id => undef });
    unlike $without, qr/tile_id/,      'clause gone when undef (no unused warn either)';
};

subtest 'an escaped @ renders literally' => sub {
    my ($sql) = $r->render(q{SELECT '%\@example.com'}, {});
    like $sql, qr/\@example\.com/, '\@ in the SQL survives vars => 1';
};

done_testing;
