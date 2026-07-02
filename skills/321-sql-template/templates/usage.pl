use strict;
use warnings;

# How the pieces fit together. Three snippets: the db helper, a model that
# calls a named query, and a controller that uses the model.

#------------------------------------------------------------------------------
# 1. The db helper - construct an F6::DB per request, in your app startup.
#------------------------------------------------------------------------------
# $app->helper(db => sub ($c) {
#     F6::DB->new(
#         db      => $c->pg->db,                    # Mojo::Pg::Database
#         sql_dir => $c->app->home->child('sql'),   # .../sql
#     );
# });

#------------------------------------------------------------------------------
# 2. A model - one method per query, binds assembled here.
#------------------------------------------------------------------------------
package F6::Model::Clicks;
use Mojo::Base -base, -signatures;

has 'db';   # an F6::DB

sub recent ($self, $array_id, %opt) {
    # Pass EVERY key the template might reference - optional ones as undef,
    # so the <% if (defined $x) %> branches see a real (undef) lexical.
    return $self->db->query('tile_clicks/recent', {
        array_id => $array_id,
        tile_id  => $opt{tile_id},          # undef -> that clause is skipped
        days     => $opt{days}  // 7,
        dir      => ($opt{dir} // '') eq 'asc' ? 'asc' : 'desc',   # allowlisted
        limit    => $opt{limit} // 5,
    })->hashes->to_array;                    # Mojo::Pg result API
}

#------------------------------------------------------------------------------
# 3. A controller action - hand the model the request db.
#------------------------------------------------------------------------------
# sub show ($c) {
#     my $rows = F6::Model::Clicks->new(db => $c->db)
#         ->recent($c->param('array_id'), days => 30);
#     $c->render(json => $rows);
# }

# Result shapes you'll reach for:
#   ->hash               # first row as a hashref (or undef)
#   ->hashes->to_array   # all rows as an arrayref of hashrefs
#   ->expand->hash       # decode json/jsonb columns first
#   ->array              # first row as an arrayref

1;
