use strict;
use warnings;

BEGIN {
    $ENV{MOJO_MODE}   ||= 'testing';
    $ENV{MOJO_CONFIG} ||= 't/conf/test-local-share.conf';
}

use Test::Most;
use lib 'lib';
use lib 't/lib';
use Test::L2D qw(test_mojo test_mojo_keep_db make_user_with_account);
use L2D::Auth::Passcodes;
use L2D::Model::Users;

#------------------------------------------------------------------------------
# sign_in - the passcode flow from t/02-auth.t: POST /signin puts the email in
#   the session, then a freshly issued (known) code completes sign-in.
#------------------------------------------------------------------------------
sub sign_in {
    my ($t, $db, $email) = @_;
    $t->post_ok('/signin' => form => { email => $email })->status_is(302);
    my $code = L2D::Auth::Passcodes->new(db => $db)->issue($email)->{code};
    $t->post_ok('/signin/code' => form => { code => $code })->status_is(302);
    return $t;
}

#------------------------------------------------------------------------------
# flash_token - the share URL is flashed after POST /share; render any page we
#   own (GET /compare/new) to read it, and pull the token out of the URL.
#------------------------------------------------------------------------------
sub flash_token {
    my ($t, $prefix) = @_;
    $t->get_ok('/compare/new')->status_is(200);
    my ($token) = $t->tx->res->body =~ m{http://localhost/\Q$prefix\E/([\w-]+)};
    return $token;
}

my ($t, $db, $owner) = make_user_with_account('owner@example.com', 'share-owner');

# Fixtures inserted directly (the Profiles/RoleSpecs slices may not exist yet).
my $profile = $db->raw(q{
    INSERT INTO love_profiles (user_id, title, summary, flower_json, profile_json)
    VALUES (?, ?, ?, ?, ?)
    RETURNING *
}, $owner->{user_id}, 'Test Love2', 'I come alive doing mentoring work',
    { json => {
        loves   => [qw(mentoring systems)],
        gives   => [qw(listening)],
        learns  => [qw(facilitation)],
        values  => [qw(craft)],
        notices => [qw(detail)],
        thrives => [qw(calm)],
    } },
    { json => { drains => [qw(travel meetings)], generated_by => 'stub-v1' } },
)->hash;

$db->raw(q{
    INSERT INTO love_profile_answers (profile_id, question_key, answer_text)
    VALUES (?, ?, ?)
}, $profile->{profile_id}, 'love_doing', 'TOPSECRETANSWER raw answer text');

my $spec = $db->raw(q{
    INSERT INTO role_specs (user_id, title, summary, source_text, flower_json, output_json)
    VALUES (?, ?, ?, ?, ?, ?)
    RETURNING *
}, $owner->{user_id}, 'Senior Mentor Role', 'The real work here centres on mentoring.',
    'RAWSOURCETEXT pasted job spec',
    { json => {
        needs   => [qw(mentoring systems)],
        rewards => [qw(calm)],
        demands => [qw(travel)],
        grows   => [qw(facilitation)],
        values  => [qw(craft)],
        drains  => [qw(meetings)],
    } },
    { json => {
        attraction_rewrite => 'This role is for someone who genuinely loves mentoring.',
        generated_by       => 'stub-v1',
    } },
)->hash;

my $comparison = $db->raw(q{
    INSERT INTO comparisons (user_id, profile_id, role_spec_id, comparison_json, summary)
    VALUES (?, ?, ?, ?, ?)
    RETURNING *
}, $owner->{user_id}, $profile->{profile_id}, $spec->{role_spec_id},
    { json => {
        score             => 80,
        strong_overlap    => [qw(mentoring systems calm craft)],
        stretch_areas     => [qw(travel)],
        mismatch_warnings => [qw(travel meetings)],
        generated_by      => 'stub-v1',
    } },
    'Strong shared ground: mentoring, systems, calm.',
)->hash;

sign_in($t, $db, 'owner@example.com');

my $anon = test_mojo_keep_db();
my ($profile_token, $role_token, $comparison_token);

subtest 'anonymous cannot create a share' => sub {
    $anon->post_ok('/share' => form => {
        resource_type => 'love_profile',
        resource_id   => $profile->{profile_id},
    })->status_is(302)->header_like(Location => qr{/signin});
};

subtest 'share a profile: flash URL, public page shows petals not answers' => sub {
    $t->post_ok('/share' => form => {
        resource_type => 'love_profile',
        resource_id   => $profile->{profile_id},
    })->status_is(302)->header_like(Location => qr{/profile});

    $profile_token = flash_token($t, 'p');
    ok $profile_token, 'flash carried a /p/ share URL';
    is length($profile_token), 24, 'token is 24 chars';

    my $hash_count = $db->raw(q{
        SELECT count(*) AS n FROM share_tokens WHERE token_hash = ?
    }, $profile_token)->hash->{n};
    is $hash_count, 0, 'raw token is not stored (only its hash)';

    $anon->get_ok("/p/$profile_token")->status_is(200)
        ->content_like(qr/Test Love2/, 'title shown')
        ->content_like(qr/I come alive doing mentoring work/, 'summary shown')
        ->content_like(qr/mentoring/, 'petal words shown')
        ->content_like(qr/Thrives/, 'six petal headings rendered')
        ->content_unlike(qr/TOPSECRETANSWER/, 'raw answer text never leaks')
        ->content_like(qr{href="/signup"}, 'viral CTA links to signup')
        ->content_like(qr/Create your own Love2/, 'viral CTA copy present');
};

subtest 'share_viewed event row written' => sub {
    my $row = $db->raw(q{
        SELECT count(*) AS n FROM events
        WHERE event_type = 'share_viewed'
        AND metadata->>'type' = 'love_profile'
    })->hash;
    is $row->{n}, 1, 'one share_viewed event for the profile view';

    my $shared = $db->raw(q{
        SELECT count(*) AS n FROM events WHERE event_type = 'profile_shared'
    })->hash;
    is $shared->{n}, 1, 'profile_shared event logged on create';
};

subtest 'share a role spec: /r/ works, wrong prefix /p/ is a 404' => sub {
    $t->post_ok('/share' => form => {
        resource_type => 'role_spec',
        resource_id   => $spec->{role_spec_id},
    })->status_is(302)->header_like(Location => qr{/role-specs/$spec->{role_spec_id}});

    $role_token = flash_token($t, 'r');
    ok $role_token, 'flash carried a /r/ share URL';

    $anon->get_ok("/p/$role_token")->status_is(404);
    $anon->get_ok("/c/$role_token")->status_is(404);

    $anon->get_ok("/r/$role_token")->status_is(200)
        ->content_like(qr/Senior Mentor Role/, 'title shown')
        ->content_like(qr/genuinely loves mentoring/, 'attraction rewrite shown')
        ->content_unlike(qr/RAWSOURCETEXT/, 'pasted source text never leaks')
        ->content_like(qr/Create your own Love2/, 'viral CTA present');
};

subtest 'share a comparison: /c/ public page shows the score' => sub {
    $t->post_ok('/share' => form => {
        resource_type => 'comparison',
        resource_id   => $comparison->{comparison_id},
    })->status_is(302)->header_like(Location => qr{/compare/$comparison->{comparison_id}});

    $comparison_token = flash_token($t, 'c');
    ok $comparison_token, 'flash carried a /c/ share URL';

    $anon->get_ok("/c/$comparison_token")->status_is(200)
        ->content_like(qr/80%/, 'score shown')
        ->content_like(qr/Strong overlap/, 'overlap section shown')
        ->content_like(qr/Mismatch warnings/, 'warnings section shown')
        ->content_like(qr/Create your own Love2/, 'viral CTA present');
};

subtest 'bogus token is a 404' => sub {
    $anon->get_ok('/p/' . ('x' x 24))->status_is(404);
    $anon->get_ok('/r/' . ('x' x 24))->status_is(404);
    $anon->get_ok('/c/' . ('x' x 24))->status_is(404);
};

subtest 'non-owner cannot share or revoke someone else\'s resource' => sub {
    L2D::Model::Users->new(db => $db)->find_or_create_by_email('other@example.com');
    my $t2 = test_mojo_keep_db();
    sign_in($t2, $db, 'other@example.com');

    $t2->post_ok('/share' => form => {
        resource_type => 'love_profile',
        resource_id   => $profile->{profile_id},
    })->status_is(404, 'cannot share another user\'s profile');

    $t2->post_ok('/share' => form => {
        resource_type => 'role_spec',
        resource_id   => $spec->{role_spec_id},
    })->status_is(404, 'cannot share another user\'s role spec');

    $t2->post_ok('/share' => form => {
        resource_type => 'comparison',
        resource_id   => $comparison->{comparison_id},
    })->status_is(404, 'cannot share another user\'s comparison');

    $t2->post_ok('/share' => form => {
        resource_type => 'users',
        resource_id   => 1,
    })->status_is(404, 'non-whitelisted resource_type rejected');

    my $share_row = $db->raw(q{
        SELECT share_token_id FROM share_tokens
        WHERE resource_type = 'love_profile'
        ORDER BY share_token_id DESC LIMIT 1
    })->hash;
    $t2->post_ok("/share/$share_row->{share_token_id}/revoke")
       ->status_is(404, 'non-owner cannot revoke');

    $anon->get_ok("/p/$profile_token")->status_is(200, 'link still live after failed revoke');
};

subtest 'owner revoke kills the public link' => sub {
    my $share_row = $db->raw(q{
        SELECT share_token_id FROM share_tokens
        WHERE resource_type = 'love_profile'
        ORDER BY share_token_id DESC LIMIT 1
    })->hash;

    $t->post_ok("/share/$share_row->{share_token_id}/revoke")
      ->status_is(302)->header_like(Location => qr{/profile});

    $anon->get_ok("/p/$profile_token")->status_is(404, 'revoked token is a 404');
    $anon->get_ok("/r/$role_token")->status_is(200, 'other tokens unaffected');
};

subtest 'expired token is a 404' => sub {
    $db->raw(q{
        UPDATE share_tokens SET expires_at = now() - interval '1 hour'
        WHERE resource_type = 'role_spec'
    });
    $anon->get_ok("/r/$role_token")->status_is(404);
};

done_testing;
