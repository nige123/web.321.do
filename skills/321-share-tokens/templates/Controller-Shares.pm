package L2D::Web::Controller::Shares;

#------------------------------------------------------------------------------
# Sharing: owner actions (create / revoke a share link) plus the public
# read-only pages behind /p/:token, /r/:token and /c/:token. Every public view
# ends in the viral CTA ("Create your own Love2") and logs a
# share_viewed event for the flywheel.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;

use L2D::Model::Shares;

my %EVENT_FOR = (
    love_profile => 'profile_shared',
    role_spec    => 'role_spec_shared',
    comparison   => 'comparison_shared',
);

#------------------------------------------------------------------------------
# create - POST /share (auth). Mint a share link for a resource the current
#   user owns, flash the full URL, and return to the resource page.
#------------------------------------------------------------------------------
sub create ($c) {

    my $user = $c->current_user;
    my $type = $c->param('resource_type') // '';
    my $id   = $c->param('resource_id')   // '';

    my $shares = L2D::Model::Shares->new(db => $c->db);

    return $c->reply->not_found
        unless $shares->valid_type($type) && $id =~ /\A[0-9]+\z/;

    my $r = $shares->create($user->{user_id}, $type, $id);

    return $c->reply->not_found unless $r->{ok};

    $c->log_event($EVENT_FOR{$type}, resource_type => $type, resource_id => $id);

    my $url = $c->config('base_url') . '/' . $shares->url_prefix($type) . '/' . $r->{token};
    $c->flash(notice => "Share link created: $url");

    return $c->redirect_to(_back_path($type, $id));
}

#------------------------------------------------------------------------------
# revoke - POST /share/:share_token_id/revoke (auth, owner-only).
#------------------------------------------------------------------------------
sub revoke ($c) {

    my $user = $c->current_user;
    my $id   = $c->stash('share_token_id') // '';

    return $c->reply->not_found unless $id =~ /\A[0-9]+\z/;

    my $row = L2D::Model::Shares->new(db => $c->db)
        ->revoke($id, $user->{user_id});

    return $c->reply->not_found unless $row;

    $c->flash(notice => 'Share link revoked.');

    return $c->redirect_to(_back_path($row->{resource_type}, $row->{resource_id}));
}

#------------------------------------------------------------------------------
# public views - GET /p/:token, /r/:token, /c/:token (no auth). A revoked,
#   expired, unknown or wrong-prefix token is a plain 404.
#------------------------------------------------------------------------------
sub profile ($c) {

    my ($share, $shares) = _resolve_share($c, 'love_profile');
    my $profile = $share ? $shares->shared_profile($share->{resource_id}) : undef;

    return $c->reply->not_found unless $profile;

    $c->log_event('share_viewed',
        resource_type => 'love_profile',
        resource_id   => $share->{resource_id},
        metadata      => { type => 'love_profile' });

    return $c->render(template => 'share/profile', profile => $profile);
}

sub role_spec ($c) {

    my ($share, $shares) = _resolve_share($c, 'role_spec');
    my $spec = $share ? $shares->shared_role_spec($share->{resource_id}) : undef;

    return $c->reply->not_found unless $spec;

    $c->log_event('share_viewed',
        resource_type => 'role_spec',
        resource_id   => $share->{resource_id},
        metadata      => { type => 'role_spec' });

    return $c->render(template => 'share/role_spec', spec => $spec);
}

sub comparison ($c) {

    my ($share, $shares) = _resolve_share($c, 'comparison');
    my $comparison = $share ? $shares->shared_comparison($share->{resource_id}) : undef;

    return $c->reply->not_found unless $comparison;

    $c->log_event('share_viewed',
        resource_type => 'comparison',
        resource_id   => $share->{resource_id},
        metadata      => { type => 'comparison' });

    return $c->render(template => 'share/comparison', comparison => $comparison);
}

#------------------------------------------------------------------------------
# _resolve_share - live share row for the URL token IF it matches the expected
#   type, plus the model (so callers can load the projection).
#------------------------------------------------------------------------------
sub _resolve_share ($c, $expected_type) {
    my $shares = L2D::Model::Shares->new(db => $c->db);
    my $share  = $shares->resolve($c->stash('token'), $expected_type);
    return ($share, $shares);
}

#------------------------------------------------------------------------------
# _back_path - the owner-facing page for a shared resource.
#------------------------------------------------------------------------------
sub _back_path ($type, $id) {
    return $type eq 'love_profile' ? '/profile'
         : $type eq 'role_spec'    ? "/role-specs/$id"
         :                           "/compare/$id";
}

1;
