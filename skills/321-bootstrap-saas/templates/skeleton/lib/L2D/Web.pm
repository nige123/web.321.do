# Copyright Nige Ltd. Author: Nigel Hamilton.
package L2D::Web;

#------------------------------------------------------------------------------
# Mojolicious application class. Wires config, database + migrations, Minion,
# request helpers (current_user / start_session_for / db / email_sender) and
# routes. This is the seam every feature skill (passkeys, stripe, sql-template)
# hooks into - keep the helper names and shapes stable.
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious', -signatures;

use Mojo::Pg;
use L2D::DB;
use L2D::Auth::Sessions;
use L2D::Email::Sender;

sub startup ($self) {

    $self->plugin('Config');
    $self->moniker($self->config('moniker') // 'l2d.web');
    $self->secrets($self->config('cookie_secrets'));

    # The Mojolicious signed-cookie session ('l2d') holds only transient
    # per-host flow state (the sign-in email in flight). Login persistence is
    # the SEPARATE DB-backed 'l2d_session' cookie. Keep this one HOST-ONLY
    # (no Domain): a Domain shares the name across apex + subdomains and a
    # stale same-name cookie then shadows the live one. See gotchas.md.
    $self->sessions->cookie_name('l2d');
    $self->sessions->default_expiration($self->config('session_max_age') // 60 * 60 * 24 * 14);
    $self->sessions->secure(1) if $self->mode eq 'production';

    push @{$self->commands->namespaces}, 'L2D::Command';

    $self->_setup_database;
    $self->_setup_minion;
    $self->_setup_helpers;
    $self->_setup_routes;

    return $self;
}

#------------------------------------------------------------------------------
# _setup_database - wire Mojo::Pg, migrations (auto-applied) and the db helper.
#   auto_migrate(1) applies pending "-- N up" blocks lazily on first DB use.
#------------------------------------------------------------------------------
sub _setup_database ($self) {

    my $pg = Mojo::Pg->new($self->config('db_connect_string'));

    $pg->migrations
       ->name('l2d')
       ->from_file($self->home->rel_file('db/migration.sql'));

    $pg->auto_migrate(1);

    $self->helper(pg => sub ($c) { return $pg });

    # db: a per-request L2D::DB wrapper around this request's Mojo::Pg::Database.
    # Callable from a controller ($c->db) or the app ($app->db, e.g. in a job).
    $self->helper(db => sub ($c_or_app) {
        my $pg_db = ref $c_or_app && $c_or_app->can('pg')
            ? $c_or_app->pg->db
            : $pg->db;
        return L2D::DB->new(
            db      => $pg_db,
            sql_dir => $self->home->rel_file('sql'),
        );
    });

    return $self;
}

#------------------------------------------------------------------------------
# _setup_minion - install Minion (Pg backend) + register async tasks.
#   Email is sent from a worker, not the request, so delivery survives the
#   request lifecycle and Minion retries transient failures with backoff.
#------------------------------------------------------------------------------
sub _setup_minion ($self) {

    $self->plugin(Minion => { Pg => $self->config('db_connect_string') });

    $self->minion->add_task(email_passcode => sub ($job, $to, $code) {
        $job->app->email_sender->send_passcode($to, $code);
    });

    # Feature skills register more tasks here - e.g. 321-stripe adds the
    # `stripe_event` (webhook processor) and `stripe_report_usage` tasks.

    return $self;
}

#------------------------------------------------------------------------------
# _setup_helpers - request helpers shared across controllers.
#------------------------------------------------------------------------------
sub _setup_helpers ($self) {

    # asset_url: append a deploy-stable version stamp to local CSS/JS links
    # so a release actually reaches browsers (cache busting). 321 hot deploys
    # swap the app with zero downtime, so nothing ever nudges a user to
    # refresh - without the stamp, browsers pair the new HTML with the old
    # cached stylesheet and the page renders half-unstyled. The git sha
    # changes with every deploy; a checkout-less environment falls back to
    # the server start time, which changes on every restart.
    my $asset_v = do {
        my $home = $self->home;
        my $sha  = qx{git -C '$home' rev-parse --short HEAD 2>/dev/null} // '';
        chomp $sha;
        length $sha ? $sha : $^T;
    };
    $self->helper(asset_url => sub ($c, $path) { "$path?v=$asset_v" });

    # current_user: resolve the DB session behind the signed 'l2d_session'
    # cookie, memoized per request. Returns { user_id, email, ... } or undef.
    $self->helper(current_user => sub ($c) {

        return $c->stash->{'l2d.user'}
            if exists $c->stash->{'l2d.user'};

        my $token   = $c->signed_cookie('l2d_session');
        my $session = $token
            ? L2D::Auth::Sessions->new(db => $c->db)->resolve($token)
            : undef;

        return $c->stash->{'l2d.user'} = $session;
    });

    # start_session_for: mint a DB session for a user and set the signed cookie.
    # The ONE place login is established - the passcode flow uses it, and the
    # 321-passkeys login ceremony reuses it verbatim.
    $self->helper(start_session_for => sub ($c, $user_id) {
        my $session = L2D::Auth::Sessions->new(db => $c->db)->create($user_id);
        $c->signed_cookie(l2d_session => $session->{token}, {
            path     => '/',
            domain   => $c->config('cookie_domain'),   # undef => host-only (dev/test)
            httponly => 1,
            samesite => 'Lax',
            secure   => ($c->app->mode eq 'production' ? 1 : 0),
            expires  => time + ($c->config('session_max_age') // 60 * 60 * 24 * 14),
        });
        return $session;
    });

    # email_sender: dual-callable (controller or app/job). Inert (logs instead
    # of sending) whenever postmark_server_token is empty - so dev + tests never
    # touch the network.
    $self->helper(email_sender => sub ($c_or_app) {
        my $app = $c_or_app->can('app') ? $c_or_app->app : $c_or_app;
        return L2D::Email::Sender->new(
            log    => $app->log,
            ua     => $app->ua,
            from   => $app->config('postmark_from_email'),
            token  => $app->config('postmark_server_token')  // '',
            stream => $app->config('postmark_message_stream') // 'outbound',
        );
    });

    return $self;
}

#------------------------------------------------------------------------------
# _setup_routes - declare application routes.
#------------------------------------------------------------------------------
sub _setup_routes ($self) {

    my $r = $self->routes;

    # public
    $r->get('/health')->to('Health#check');
    $r->get('/')->to('Home#landing')->name('home');

    # auth (email passcode)
    $r->get('/signup')->to('Signup#new_form');
    $r->post('/signup')->to('Signup#create');
    $r->get('/signin')->to('Auth#signin_form');
    $r->post('/signin')->to('Auth#signin_submit');
    $r->get('/signin/code')->to('Auth#code_form');
    $r->post('/signin/code')->to('Auth#code_submit');
    $r->post('/signout')->to('Auth#signout');

    # public account page - keep LAST of the top-level GETs so literal paths win
    $r->get('/@:handle')->to('Accounts#show');

    # authenticated area: everything under $auth requires a signed-in user
    my $auth = $r->under('/' => sub ($c) {
        return 1 if $c->current_user;
        $c->redirect_to('/signin');
        return undef;
    });
    # $auth->get('/dashboard')->to('Dashboard#index');

    return $self;
}

1;
