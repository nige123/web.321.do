#!/usr/bin/env perl

# 321.do — standalone deploy and log analysis service
# See CLAUDE.md for full specification

use Mojolicious::Lite -signatures;
use Mojo::File qw(curfile);
use Mojo::Util qw(decode);

app->config(hypnotoad => {listen => ['http://127.0.0.1:9321']});
unshift @{app->commands->namespaces}, 'Deploy::Command';

my $app_home = $ENV{APP_HOME} // curfile->dirname->dirname;
use lib curfile->dirname->dirname->child('lib')->to_string;

use Deploy::Config;
use Deploy::Service;
use Deploy::Logs;
use Deploy::Ubic;
use Deploy::Nginx;
use Deploy::Transport;
use Text::Markdown qw(markdown);

# --- Config ---

my $config = Deploy::Config->new(app_home => $app_home);

my $ubic_mgr = Deploy::Ubic->new(
    config => $config,
    log    => app->log,
);

my $service_mgr = Deploy::Service->new(
    config   => $config,
    log      => app->log,
    ubic_mgr => $ubic_mgr,
);

my $logs_mgr = Deploy::Logs->new(
    config => $config,
);

my $nginx_mgr = Deploy::Nginx->new(
    config => $config,
    log    => app->log,
);

# --- Helpers ---

# App-level accessors for command modules
app->attr(config_obj    => sub { $config });
app->attr(ubic_mgr_obj  => sub { $ubic_mgr });
app->attr(nginx_mgr_obj => sub { $nginx_mgr });
app->attr(svc_mgr_obj   => sub { $service_mgr });
app->attr(log_mgr_obj   => sub { $logs_mgr });

helper config    => sub { $config };
helper svc_mgr   => sub { $service_mgr };
helper log_mgr   => sub { $logs_mgr };
helper ubic_mgr  => sub { $ubic_mgr };
helper nginx_mgr => sub { $nginx_mgr };

helper available_targets => sub ($c) {
    my %seen;
    my @targets;
    for my $name (@{ $config->service_names }) {
        my $raw = $config->service_raw($name);
        push @targets, keys %{ $raw->{targets} // {} };
    }
    return [ sort grep { !$seen{$_}++ } @targets ];
};

helper json_response => sub ($c, $status, $message, $data = {}) {
    $c->render(json => { status => $status, message => $message, data => $data });
};

helper git_commit => sub ($self, $file, $msg) {
    system('git', '-C', $app_home, 'add', $file) == 0
        or app->log->warn("git add failed for $file");
    system('git', '-C', $app_home, 'commit', '-m', $msg, '--', $file) == 0
        or app->log->warn("git commit failed: $msg");
};

helper validate_service => sub ($c, $name) {
    unless ($config->service($name)) {
        $c->json_response(error => "Unknown service: $name");
        return 0;
    }
    return 1;
};

# --- Routes ---

# Health check (no auth required)
get '/health' => sub ($c) {
    my $services = $service_mgr->all_status;
    my $healthy = grep { ${$_->{running}} } @$services;
    my $total = scalar @$services;

    $c->json_response(success => '321.do is running', {
        service   => '321.do',
        uptime    => time - $^T,
        services  => {
            total   => $total,
            running => $healthy,
        },
    });
};

# List all services
get '/services' => sub ($c) {
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    my $services = $service_mgr->all_status;
    $c->json_response(success => scalar(@$services) . ' services registered', $services);
};

# Service status
get '/service/#name/status' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $status = $service_mgr->status($name);
    $c->json_response(success => "Status for $name", $status);
};

# Deploy a service (production: git pull + cpanm + ubic restart)
post '/service/#name/deploy' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $svc       = $config->service($name);
    my $transport = Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
    $service_mgr->transport($transport);

    app->log->info("Deploy requested for $name");
    my $result = $service_mgr->deploy($name);
    $c->render(json => $result);
};

# Update (git pull + cpanm + migrate, no restart)
post '/service/#name/update' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $svc       = $config->service($name);
    my $transport = Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
    $service_mgr->transport($transport);

    my $result = $service_mgr->update($name);
    $c->render(json => $result);
};

# Run database migrations only
post '/service/#name/migrate' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $svc       = $config->service($name);
    my $transport = Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
    $service_mgr->transport($transport);

    my $result = $service_mgr->migrate($name);
    $c->render(json => $result);
};

# Restart via service manager (ubic restart + port check)
post '/service/#name/restart' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $svc       = $config->service($name);
    my $transport = Deploy::Transport->for_target($svc, perlbrew => $svc->{perlbrew});
    $service_mgr->transport($transport);

    my $result = $service_mgr->restart($name);
    $c->render(json => $result);
};

# Start/stop a service via ubic
for my $action (qw(start stop)) {
    post "/service/#name/$action" => sub ($c) {
        my $name   = $c->param('name');
        my $target = $c->param('target') // 'dev';
        $config->target($target);
        return unless $c->validate_service($name);

        app->log->info("$action requested for $name");
        my $output = `ubic $action $name 2>&1`;
        my $ok = $? == 0;
        my $label = ucfirst($action);
        $c->json_response(
            ($ok ? 'success' : 'error'),
            ($ok ? "$label $name" : "$label failed for $name"),
            { output => $output },
        );
    };
}

# Tail logs
get '/service/#name/logs' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $type = $c->param('type') // 'stderr';
    my $n    = $c->param('n')    // 100;
    $n = int($n);
    $n = 1000 if $n > 1000;

    my $result = $logs_mgr->tail($name, $type, $n);
    $c->render(json => $result);
};

# Search logs
get '/service/#name/logs/search' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $query = $c->param('q');
    unless ($query) {
        return $c->json_response(error => 'Missing query parameter: q');
    }

    my $type = $c->param('type') // 'stderr';
    my $n    = $c->param('n')    // 50;
    $n = int($n);
    $n = 500 if $n > 500;

    my $result = $logs_mgr->search($name, $query, $type, $n);
    $c->render(json => $result);
};

# Analyse logs
get '/service/#name/logs/analyse' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);

    my $n = $c->param('n') // 1000;
    $n = int($n);
    $n = 10000 if $n > 10000;

    my $result = $logs_mgr->analyse($name, $n);
    $c->render(json => $result);
};

# --- Config CRUD ---

# Get raw service config (decrypted)
get '/service/#name/config' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);
    my $raw = $config->service_raw($name);
    $c->json_response(success => "Config for $name", $raw);
};

# --- Git operations ---

get '/git/status' => sub ($c) {
    my $ahead = `cd \Q$app_home\E && git rev-list \@{u}..HEAD 2>/dev/null | wc -l`;
    chomp $ahead;
    $ahead = int($ahead // 0);
    my $branch = `cd \Q$app_home\E && git branch --show-current 2>/dev/null`;
    chomp $branch;
    $c->json_response(success => 'Git status', {
        unpushed => $ahead,
        branch   => $branch,
    });
};

# --- Nginx management ---

get '/service/#name/nginx' => sub ($c) {
    my $name   = $c->param('name');
    my $target = $c->param('target') // 'dev';
    $config->target($target);
    return unless $c->validate_service($name);
    my $status = $nginx_mgr->status($name);
    $c->json_response(success => "Nginx status for $name", $status);
};

# --- UI Routes ---

get '/' => sub ($c) {
    $c->render('dashboard');
};

get '/ui/service/#name' => sub ($c) {
    my $name = $c->param('name');
    $c->stash(service_name => $name);
    $c->render('service_detail');
};

get '/ui/add' => sub ($c) {
    $c->render('add_subsystem');
};

get '/docs' => sub ($c) {
    my $file = $app_home->child('docs', 'ops.md');
    return $c->render(text => 'Docs not found', status => 404) unless -f $file;
    my $html = markdown(decode('UTF-8', $file->slurp));
    $c->render(template => 'docs', doc_html => $html);
};

app->start;

__DATA__

@@ layouts/ops.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><%= title %> — 321.do</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='6' fill='%23010a01'/%3E%3Cpolygon points='12,8 12,24 26,16' fill='%2300ff41'/%3E%3C/svg%3E">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600;700&family=Orbitron:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>

/* ═══ CORE ═══ */

:root {
    --void: #010a01;
    --panel: #071207;
    --panel-2: #0c1a0c;
    --panel-3: #112211;
    --border: #163016;
    --border-hi: #1e4e1e;
    --phosphor: #00ff41;
    --phosphor-mid: #00cc33;
    --phosphor-dim: #00802a;
    --phosphor-faint: #004d19;
    --phosphor-glow: rgba(0, 255, 65, 0.2);
    --phosphor-glow-strong: rgba(0, 255, 65, 0.4);
    --amber: #ffa000;
    --amber-dim: #cc8000;
    --amber-glow: rgba(255, 160, 0, 0.15);
    --red: #ff0033;
    --red-dim: #cc0029;
    --red-glow: rgba(255, 0, 51, 0.15);
    --cyan: #00e5ff;
    --cyan-glow: rgba(0, 229, 255, 0.12);
    --dev: #b388ff;
    --dev-dim: #7c4dff;
    --dev-glow: rgba(179, 136, 255, 0.15);
    --text-0: #c0ffc0;
    --text-1: #70b070;
    --text-2: #3a6b3a;
    --display: 'Orbitron', sans-serif;
    --mono: 'IBM Plex Mono', 'Courier New', monospace;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
    background-color: var(--void);
    background-image:
        radial-gradient(ellipse at 50% 0%, rgba(0, 255, 65, 0.015) 0%, transparent 70%),
        linear-gradient(rgba(0, 255, 65, 0.025) 1px, transparent 1px),
        linear-gradient(90deg, rgba(0, 255, 65, 0.025) 1px, transparent 1px);
    background-size: 100% 100%, 48px 48px, 48px 48px;
    color: var(--text-0);
    font-family: var(--mono);
    font-size: 22px;
    line-height: 1.5;
    min-height: 100vh;
    overflow-x: hidden;
}

::-webkit-scrollbar { width: 6px; height: 6px; }
::-webkit-scrollbar-track { background: var(--void); }
::-webkit-scrollbar-thumb { background: var(--border); }
::-webkit-scrollbar-thumb:hover { background: var(--border-hi); }

/* ═══ CRT EFFECTS ═══ */

#rain {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    z-index: 0;
    pointer-events: none;
}

body::before {
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(
        0deg,
        transparent,
        transparent 2px,
        rgba(0, 0, 0, 0.06) 2px,
        rgba(0, 0, 0, 0.06) 4px
    );
    pointer-events: none;
    z-index: 10000;
}

body::after {
    content: '';
    position: fixed;
    inset: 0;
    background: radial-gradient(ellipse at center, transparent 55%, rgba(0, 0, 0, 0.45) 100%);
    pointer-events: none;
    z-index: 9999;
}

/* ═══ MISSION BAR ═══ */

.mission-bar {
    position: sticky;
    top: 0;
    z-index: 100;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    padding: 0 24px;
    height: 56px;
    display: flex;
    align-items: center;
    gap: 20px;
    overflow: hidden;
}

.mission-bar::after {
    content: '';
    position: absolute;
    top: 0;
    left: -50%;
    width: 30%;
    height: 100%;
    background: linear-gradient(90deg, transparent, rgba(0, 255, 65, 0.03), transparent);
    animation: bar-sweep 8s linear infinite;
    pointer-events: none;
}

.mission-logo {
    font-family: var(--display);
    font-weight: 700;
    font-size: 19px;
    color: var(--phosphor);
    text-decoration: none;
    display: flex;
    align-items: center;
    gap: 8px;
    text-shadow: 0 0 12px var(--phosphor-glow);
    flex-shrink: 0;
}

.mission-logo .logo-svg {
    filter: drop-shadow(0 0 6px rgba(0, 255, 65, 0.3));
}

.mission-title {
    font-family: var(--display);
    font-size: 18px;
    font-weight: 500;
    letter-spacing: 4px;
    color: var(--text-2);
    text-transform: uppercase;
    white-space: nowrap;
}

.dev-badge {
    font-family: var(--display);
    font-size: 13px;
    font-weight: 700;
    color: var(--dev);
    background: var(--dev-glow);
    border: 1px solid var(--dev-dim);
    padding: 3px 10px;
    letter-spacing: 2px;
}

.mission-link {
    font-family: var(--display);
    font-size: 14px;
    font-weight: 500;
    letter-spacing: 3px;
    color: var(--text-2);
    text-decoration: none;
    padding: 4px 10px;
    border: 1px solid transparent;
    transition: color 120ms, border-color 120ms;
}

.mission-link:hover {
    color: var(--phosphor);
    border-color: var(--phosphor-faint);
}

.mission-clock {
    font-family: var(--display);
    font-size: 18px;
    font-weight: 400;
    color: var(--phosphor-mid);
    letter-spacing: 2px;
    margin-left: auto;
    white-space: nowrap;
}

.health-badge {
    font-size: 18px;
    padding: 4px 12px;
    display: flex;
    align-items: center;
    gap: 8px;
    letter-spacing: 1px;
    white-space: nowrap;
    flex-shrink: 0;
}

.health-badge.ok {
    color: var(--phosphor);
    background: rgba(0, 255, 65, 0.06);
    border: 1px solid var(--phosphor-faint);
}

.health-badge.down {
    color: var(--red);
    background: rgba(255, 0, 51, 0.06);
    border: 1px solid rgba(255, 0, 51, 0.3);
    animation: alert-flash 2s ease-in-out infinite;
}

.target-switch {
    display: flex;
    background: var(--void);
    padding: 2px;
    gap: 1px;
}

.target-btn {
    font-family: var(--display);
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 2px;
    padding: 4px 14px;
    border: none;
    background: transparent;
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.2s;
    text-transform: uppercase;
}

.target-btn:hover { color: var(--text-1); }

.target-btn.active-live {
    background: var(--phosphor-faint);
    color: var(--phosphor);
    text-shadow: 0 0 8px var(--phosphor-glow);
}

.target-btn.active-dev {
    background: rgba(179, 136, 255, 0.15);
    color: var(--dev);
    text-shadow: 0 0 8px var(--dev-glow);
}

.git-badge {
    font-size: 19px;
    padding: 4px 12px;
    display: flex;
    align-items: center;
    gap: 6px;
    letter-spacing: 1px;
    white-space: nowrap;
    flex-shrink: 0;
    cursor: pointer;
    transition: all 0.2s;
    font-family: var(--display);
    font-weight: 600;
}

.git-badge.synced {
    color: var(--phosphor-dim);
    background: rgba(0, 255, 65, 0.03);
    border: 1px solid rgba(0, 255, 65, 0.1);
}

.git-badge.unpushed {
    color: var(--amber);
    background: rgba(255, 160, 0, 0.08);
    border: 1px solid rgba(255, 160, 0, 0.25);
}

.git-badge:hover {
    background: rgba(255, 160, 0, 0.15);
    border-color: var(--amber);
    color: var(--amber);
}

/* ═══ LAYOUT ═══ */

.main {
    max-width: 1200px;
    margin: 0 auto;
    padding: 32px 24px;
    position: relative;
    z-index: 1;
}

.page-header {
    margin-bottom: 32px;
}

.page-title {
    font-family: var(--display);
    font-weight: 700;
    font-size: 26px;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: var(--phosphor);
    text-shadow: 0 0 20px var(--phosphor-glow);
    margin-bottom: 4px;
}

.page-title::after {
    content: '\2588';
    animation: blink-cursor 1s step-end infinite;
    color: var(--phosphor);
    margin-left: 4px;
    font-size: 22px;
}

.page-subtitle {
    font-size: 19px;
    color: var(--text-2);
    letter-spacing: 2px;
    text-transform: uppercase;
}

.back-link {
    color: var(--text-2);
    text-decoration: none;
    margin-right: 8px;
    transition: color 0.2s;
}

.back-link:hover {
    color: var(--phosphor);
    text-shadow: 0 0 8px var(--phosphor-glow);
}

/* ═══ SUBSYSTEM PANELS ═══ */

.svc-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 16px;
}

.svc-card {
    --bracket: var(--phosphor-faint);
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 24px;
    position: relative;
    transition: all 0.3s;
    overflow: hidden;
    animation: panel-boot 0.5s ease-out backwards;
}

.svc-card:nth-child(1) { animation-delay: 0s; }
.svc-card:nth-child(2) { animation-delay: 0.08s; }
.svc-card:nth-child(3) { animation-delay: 0.16s; }
.svc-card:nth-child(4) { animation-delay: 0.24s; }
.svc-card:nth-child(5) { animation-delay: 0.32s; }
.svc-card:nth-child(6) { animation-delay: 0.4s; }

.svc-card::before,
.svc-card::after {
    content: '';
    position: absolute;
    width: 20px;
    height: 20px;
    transition: border-color 0.3s;
}

.svc-card::before {
    top: -1px;
    left: -1px;
    border-top: 2px solid var(--bracket);
    border-left: 2px solid var(--bracket);
}

.svc-card::after {
    bottom: -1px;
    right: -1px;
    border-bottom: 2px solid var(--bracket);
    border-right: 2px solid var(--bracket);
}

.svc-card.running {
    --bracket: var(--phosphor);
    border-top-color: var(--phosphor-dim);
}

.svc-card.stopped {
    --bracket: var(--red);
    border-top-color: var(--red-dim);
}

.svc-card.dev-mode.running {
    --bracket: var(--dev);
    border-top-color: var(--dev-dim);
}

.svc-card:hover {
    border-color: var(--border-hi);
    box-shadow: 0 0 30px rgba(0, 255, 65, 0.04);
    transform: translateY(-2px);
}

.svc-card.dev-mode:hover {
    box-shadow: 0 0 30px rgba(179, 136, 255, 0.04);
}

/* ═══ CARD INTERNALS ═══ */

.svc-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 16px;
}

.svc-name {
    font-family: var(--display);
    font-size: 19px;
    font-weight: 600;
    letter-spacing: 1px;
}

.svc-name a {
    color: var(--text-0);
    text-decoration: none;
    transition: all 0.2s;
}

.svc-name a:hover {
    color: var(--phosphor);
    text-shadow: 0 0 8px var(--phosphor-glow);
}

.svc-card.dev-mode .svc-name a:hover {
    color: var(--dev);
    text-shadow: 0 0 8px var(--dev-glow);
}

.status-led {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    flex-shrink: 0;
    margin-top: 4px;
}

.status-led.on {
    background: var(--phosphor);
    box-shadow: 0 0 8px var(--phosphor), 0 0 20px var(--phosphor-glow);
    animation: pulse-led 2s ease-in-out infinite;
}

.status-led.off {
    background: var(--red);
    box-shadow: 0 0 8px var(--red), 0 0 16px var(--red-glow);
}

.mode-badge {
    font-family: var(--display);
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 2px;
    padding: 2px 8px;
    text-transform: uppercase;
    margin-left: 10px;
    vertical-align: middle;
}

.mode-badge.prod {
    color: var(--phosphor);
    background: rgba(0, 255, 65, 0.08);
    border: 1px solid var(--phosphor-faint);
}

.mode-badge.dev {
    color: var(--dev);
    background: rgba(179, 136, 255, 0.08);
    border: 1px solid var(--dev-dim);
}

/* ═══ READOUTS ═══ */

.svc-meta {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 4px 16px;
    font-size: 19px;
    margin-bottom: 16px;
}

.svc-meta dt {
    color: var(--text-2);
    font-size: 18px;
    letter-spacing: 2px;
    text-transform: uppercase;
    padding-top: 2px;
}

.svc-meta dd {
    color: var(--phosphor-mid);
    font-size: 19px;
}

/* ═══ CONTROLS ═══ */

.svc-actions {
    display: flex;
    gap: 8px;
    padding-top: 16px;
    border-top: 1px solid var(--border);
    flex-wrap: wrap;
}

.btn {
    font-family: var(--mono);
    font-size: 18px;
    letter-spacing: 1px;
    text-transform: uppercase;
    padding: 7px 14px;
    border: 1px solid var(--border);
    background: transparent;
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.2s;
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.btn-icon {
    width: 14px;
    height: 14px;
    fill: currentColor;
    flex-shrink: 0;
}

.btn:hover {
    background: var(--panel-2);
    color: var(--text-1);
    border-color: var(--border-hi);
}

.svc-controls {
    border-top: none;
    padding-top: 4px;
}

.btn-ctrl {
    font-size: 16px;
    letter-spacing: 2px;
    padding: 5px 10px;
}

.btn-tint {
    color: var(--btn-c);
    border-color: var(--btn-b);
}

.btn-tint:hover {
    color: var(--btn-c);
    background: var(--btn-g);
    border-color: var(--btn-c);
}

.btn-stop   { --btn-c: var(--red);   --btn-b: rgba(255,0,51,0.2);   --btn-g: var(--red-glow); }
.btn-docs   { --btn-c: var(--amber); --btn-b: rgba(255,160,0,0.2);  --btn-g: var(--amber-glow); }
.btn-admin  { --btn-c: var(--dev);   --btn-b: rgba(179,136,255,0.2); --btn-g: var(--dev-glow); }
.btn-visit  { --btn-c: var(--cyan);  --btn-b: rgba(0,229,255,0.2);  --btn-g: var(--cyan-glow); }

.btn-deploy {
    font-family: var(--display);
    font-weight: 700;
    font-size: 18px;
    letter-spacing: 3px;
    padding: 10px 20px;
    background: rgba(0, 255, 65, 0.05);
    border: 1px solid var(--phosphor-dim);
    color: var(--phosphor);
    position: relative;
    overflow: hidden;
    transition: all 0.3s;
}

.btn-deploy::after {
    content: '';
    position: absolute;
    top: 0;
    left: -100%;
    width: 100%;
    height: 100%;
    background: linear-gradient(90deg, transparent, rgba(0, 255, 65, 0.08), transparent);
    transition: left 0.5s;
}

.btn-deploy:hover {
    background: rgba(0, 255, 65, 0.12);
    border-color: var(--phosphor);
    box-shadow: 0 0 20px var(--phosphor-glow), inset 0 0 20px rgba(0, 255, 65, 0.05);
    text-shadow: 0 0 10px var(--phosphor-glow);
}

.btn-deploy:hover::after {
    left: 100%;
}

.btn-deploy:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.btn-deploy.deploying {
    border-color: var(--amber);
    color: var(--amber);
    text-shadow: 0 0 10px var(--amber-glow);
    animation: deploy-pulse 0.8s ease-in-out infinite;
}

.btn-deploy-dev {
    font-family: var(--display);
    font-weight: 700;
    font-size: 18px;
    letter-spacing: 3px;
    padding: 10px 20px;
    background: rgba(179, 136, 255, 0.05);
    border: 1px solid var(--dev-dim);
    color: var(--dev);
    position: relative;
    overflow: hidden;
    transition: all 0.3s;
}

.btn-deploy-dev::after {
    content: '';
    position: absolute;
    top: 0;
    left: -100%;
    width: 100%;
    height: 100%;
    background: linear-gradient(90deg, transparent, rgba(179, 136, 255, 0.08), transparent);
    transition: left 0.5s;
}

.btn-deploy-dev:hover {
    background: rgba(179, 136, 255, 0.12);
    border-color: var(--dev);
    box-shadow: 0 0 20px var(--dev-glow), inset 0 0 20px rgba(179, 136, 255, 0.05);
    text-shadow: 0 0 10px var(--dev-glow);
}

.btn-deploy-dev:hover::after {
    left: 100%;
}

.btn-deploy-dev:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.btn-deploy-dev.deploying {
    border-color: var(--amber);
    color: var(--amber);
    text-shadow: 0 0 10px var(--amber-glow);
    animation: deploy-pulse 0.8s ease-in-out infinite;
}

/* ═══ DEPLOY OUTPUT ═══ */

.deploy-output {
    display: none;
    margin-top: 14px;
    background: var(--void);
    border: 1px solid var(--border);
    padding: 10px 12px;
    font-size: 16px;
    line-height: 1.5;
    max-height: 520px;
    overflow-y: auto;
    color: var(--text-1);
}

.deploy-output.visible { display: block; }

.lifecycle-row {
    display: flex;
    gap: 6px;
    margin-top: 6px;
}
.lifecycle-row .btn {
    flex: 1;
    justify-content: center;
    font-size: 13px;
    padding: 6px 8px;
}

.deploy-output .step-ok { color: var(--phosphor); text-shadow: 0 0 8px var(--phosphor-glow); }
.deploy-output .step-fail { color: var(--red); text-shadow: 0 0 8px var(--red-glow); }
.deploy-output .step-label { color: var(--text-2); }

.badge { display:inline-block; padding:2px 6px; border-radius:3px; font-size:11px; margin-left:6px; vertical-align:middle; }
.badge-ok   { background:var(--accent); color:var(--bg); }
.badge-warn { background:#c33; color:#fff; }
.secrets-heading { font-size: 12px; margin: 8px 0 4px; color: var(--accent); }
.secrets-list { display: flex; flex-direction: column; gap: 4px; }
.secret-row { display: flex; align-items: center; gap: 6px; padding: 4px 0; font-size: 12px; flex-wrap: wrap; }
.secret-key { font-weight: 600; min-width: 120px; }
.secret-status { font-size: 10px; padding: 1px 5px; border-radius: 2px; }
.secret-status.set { background: var(--accent); color: var(--bg); }
.secret-status.missing { background: #c33; color: #fff; }
.secret-status.default { opacity: 0.5; }
.secret-hint { font-size: 10px; opacity: 0.6; }
.secret-input { background: var(--surface); border: 1px solid var(--border); color: var(--fg); padding: 3px 6px; font-size: 11px; width: 140px; border-radius: 3px; }
.btn-sm { font-size: 10px; padding: 3px 8px; }
.btn-danger { color: #c33; }
.secrets-optional { margin-top: 8px; }
.secrets-optional summary { cursor: pointer; font-size: 11px; opacity: 0.7; }
.secrets-none { font-size: 11px; opacity: 0.5; padding: 8px 0; }

.deploy-step { margin: 4px 0; }
.deploy-step > summary {
    cursor: pointer;
    list-style: none;
    padding: 2px 4px;
    font-family: var(--mono);
}
.deploy-step > summary::-webkit-details-marker { display: none; }
.deploy-step > summary:hover { background: var(--panel-2); }
.deploy-step[open] > summary { background: var(--panel-2); }
.deploy-step .step-body {
    margin: 4px 0 8px 20px;
    padding: 8px 10px;
    background: var(--panel);
    border-left: 2px solid var(--border-hi);
    white-space: pre-wrap;
    word-break: break-word;
    font-family: var(--mono);
    font-size: 14px;
    color: var(--text-0);
    max-height: 360px;
    overflow-y: auto;
}
.deploy-step[data-ok="0"] .step-body { border-left-color: var(--red); }

/* ═══ TERMINAL ═══ */

.log-viewer {
    background: var(--void);
    border: 1px solid var(--border);
    overflow: hidden;
}

.log-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
    flex-wrap: wrap;
}

.log-type-tabs {
    display: flex;
    gap: 2px;
    background: var(--void);
    padding: 2px;
}

.log-type-tab {
    font-family: var(--mono);
    font-size: 18px;
    padding: 5px 12px;
    border: none;
    background: transparent;
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.2s;
    letter-spacing: 1px;
    text-transform: uppercase;
}

.log-type-tab:hover { color: var(--text-1); }

.log-type-tab.active {
    background: var(--panel-2);
    color: var(--phosphor);
    text-shadow: 0 0 8px var(--phosphor-glow);
}

.log-search {
    margin-left: auto;
    display: flex;
    gap: 4px;
}

.log-search input {
    font-family: var(--mono);
    font-size: 19px;
    padding: 5px 10px;
    background: var(--void);
    border: 1px solid var(--border);
    color: var(--phosphor);
    width: 200px;
    outline: none;
    transition: border-color 0.2s;
    letter-spacing: 1px;
}

.log-search input:focus {
    border-color: var(--phosphor-dim);
    box-shadow: 0 0 10px rgba(0, 255, 65, 0.08);
}

.log-search input::placeholder { color: var(--text-2); }

.log-content {
    padding: 14px;
    font-size: 18px;
    line-height: 1.7;
    max-height: 500px;
    overflow-y: auto;
    color: var(--text-1);
    white-space: pre;
    overflow-x: auto;
    text-shadow: 0 0 3px rgba(0, 255, 65, 0.08);
}

.log-content .log-error { color: var(--red); text-shadow: 0 0 6px var(--red-glow); }
.log-content .log-warn { color: var(--amber); text-shadow: 0 0 6px var(--amber-glow); }
.log-content .log-info { color: var(--text-2); text-shadow: none; }

.log-content .log-highlight {
    background: rgba(255, 160, 0, 0.15);
    padding: 0 3px;
    color: var(--amber);
}

.log-empty {
    color: var(--text-2);
    text-align: center;
    padding: 40px 0;
    letter-spacing: 2px;
    text-transform: uppercase;
    font-size: 18px;
}

/* ═══ DIAGNOSTICS ═══ */

.analysis-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin-top: 16px;
}

.analysis-card {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 16px;
}

.analysis-card h3 {
    font-family: var(--display);
    font-size: 14px;
    font-weight: 600;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: var(--text-2);
    margin-bottom: 12px;
}

.stat-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 6px 0;
    border-bottom: 1px solid rgba(0, 255, 65, 0.04);
    font-size: 19px;
}

.stat-row:last-child { border-bottom: none; }
.stat-label { color: var(--text-1); }
.stat-value { color: var(--text-0); }
.stat-value.error { color: var(--red); text-shadow: 0 0 6px var(--red-glow); }
.stat-value.warn { color: var(--amber); text-shadow: 0 0 6px var(--amber-glow); }
.stat-value.ok { color: var(--phosphor); text-shadow: 0 0 6px var(--phosphor-glow); }

.status-code-grid {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
}

.status-code-chip {
    font-size: 19px;
    padding: 4px 10px;
    display: flex;
    gap: 6px;
    align-items: center;
}

.status-code-chip.s2xx { background: rgba(0, 255, 65, 0.08); color: var(--phosphor); border: 1px solid var(--phosphor-faint); }
.status-code-chip.s3xx { background: var(--cyan-glow); color: var(--cyan); border: 1px solid rgba(0, 229, 255, 0.2); }
.status-code-chip.s4xx { background: var(--amber-glow); color: var(--amber); border: 1px solid rgba(255, 160, 0, 0.2); }
.status-code-chip.s5xx { background: var(--red-glow); color: var(--red); border: 1px solid rgba(255, 0, 51, 0.2); }
.status-code-chip .count { opacity: 0.6; }

/* ═══ DETAIL VIEW ═══ */

.detail-grid {
    display: grid;
    grid-template-columns: 320px 1fr;
    gap: 24px;
    align-items: start;
}

.detail-sidebar {
    position: sticky;
    top: 76px;
}

.detail-info {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 24px;
    position: relative;
}

.detail-info::before,
.detail-info::after {
    content: '';
    position: absolute;
    width: 20px;
    height: 20px;
}

.detail-info::before {
    top: -1px;
    left: -1px;
    border-top: 2px solid var(--phosphor-dim);
    border-left: 2px solid var(--phosphor-dim);
}

.detail-info::after {
    bottom: -1px;
    right: -1px;
    border-bottom: 2px solid var(--phosphor-dim);
    border-right: 2px solid var(--phosphor-dim);
}

.detail-info h2 {
    font-family: var(--display);
    font-size: 19px;
    font-weight: 700;
    letter-spacing: 2px;
    margin-bottom: 16px;
    display: flex;
    align-items: center;
    gap: 12px;
    color: var(--phosphor);
    text-shadow: 0 0 12px var(--phosphor-glow);
}

.detail-meta {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 8px 16px;
    font-size: 19px;
    margin-bottom: 20px;
}

.detail-meta dt {
    color: var(--text-2);
    font-size: 18px;
    letter-spacing: 2px;
    text-transform: uppercase;
    padding-top: 2px;
}

.detail-meta dd {
    color: var(--phosphor-mid);
    font-size: 19px;
    word-break: break-all;
}

.section-title {
    font-family: var(--display);
    font-size: 19px;
    font-weight: 600;
    letter-spacing: 3px;
    text-transform: uppercase;
    margin-bottom: 12px;
    color: var(--text-1);
    display: flex;
    align-items: center;
    gap: 12px;
}

.section-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border), transparent);
}

/* ═══ CONFIG EDITOR ═══ */

.config-editor {
    background: var(--void);
    border: 1px solid var(--border);
    overflow: hidden;
}

.config-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--panel);
    border-bottom: 1px solid var(--border);
}

.config-target-tabs {
    display: flex;
    gap: 2px;
    background: var(--void);
    padding: 2px;
}

.config-target-tab {
    font-family: var(--mono);
    font-size: 18px;
    padding: 5px 12px;
    border: none;
    background: transparent;
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.2s;
    letter-spacing: 1px;
    text-transform: uppercase;
}

.config-target-tab:hover { color: var(--text-1); }

.config-target-tab.active {
    background: var(--panel-2);
    color: var(--phosphor);
    text-shadow: 0 0 8px var(--phosphor-glow);
}

.config-fields {
    padding: 14px;
}

.config-row {
    display: grid;
    grid-template-columns: 120px 1fr;
    gap: 8px;
    align-items: center;
    margin-bottom: 8px;
}

.config-label {
    font-size: 18px;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: var(--text-2);
}

.config-input {
    font-family: var(--mono);
    font-size: 19px;
    padding: 6px 10px;
    background: var(--panel);
    border: 1px solid var(--border);
    color: var(--phosphor-mid);
    outline: none;
    transition: border-color 0.2s;
    width: 100%;
}

.config-input:focus {
    border-color: var(--phosphor-dim);
    color: var(--phosphor);
}

.config-input.secret {
    color: var(--amber);
}

.btn-save-dirty {
    color: var(--amber);
    border-color: var(--amber);
    background: var(--amber-glow);
    animation: deploy-pulse 1.5s ease-in-out infinite;
}

.config-section-label {
    font-family: var(--display);
    font-size: 14px;
    font-weight: 600;
    letter-spacing: 3px;
    color: var(--text-2);
    margin: 16px 0 8px;
    padding-bottom: 4px;
    border-bottom: 1px solid var(--border);
}

/* ═══ ADD SUBSYSTEM ═══ */

.add-subsystem-form {
    background: var(--panel);
    border: 1px dashed var(--border-hi);
    padding: 20px;
}

.add-form-title {
    font-family: var(--display);
    font-size: 17px;
    font-weight: 700;
    letter-spacing: 3px;
    color: var(--text-2);
    margin-bottom: 16px;
}

.add-subsystem-btn {
    font-family: var(--display);
    font-weight: 700;
    font-size: 18px;
    letter-spacing: 3px;
    padding: 12px 24px;
    background: transparent;
    border: 1px dashed var(--border-hi);
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.3s;
    width: 100%;
    min-height: 100px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    text-decoration: none;
}

.add-subsystem-btn:hover {
    border-color: var(--phosphor-dim);
    color: var(--phosphor);
    background: rgba(0, 255, 65, 0.03);
    text-decoration: none;
}

/* Add Service page */

.add-page {
    max-width: 1200px;
    margin: 0 auto;
}

.add-page-grid {
    display: grid;
    grid-template-columns: 420px 1fr;
    gap: 32px;
    align-items: start;
}

.add-panel {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 28px;
}

.add-field {
    margin-bottom: 20px;
}

.add-label {
    display: block;
    font-family: var(--mono);
    font-size: 12px;
    font-weight: 500;
    letter-spacing: 1px;
    color: var(--text-1);
    margin-bottom: 6px;
    text-transform: uppercase;
}

.add-label-sm {
    display: block;
    font-family: var(--mono);
    font-size: 11px;
    font-weight: 400;
    color: var(--text-2);
    margin-bottom: 4px;
}

.add-input {
    font-family: var(--mono);
    font-size: 15px;
    padding: 8px 12px;
    background: var(--void);
    border: 1px solid var(--border);
    color: var(--phosphor-mid);
    outline: none;
    transition: border-color 0.2s;
    width: 100%;
}

.add-input:focus {
    border-color: var(--phosphor-dim);
    color: var(--phosphor);
}

.add-input::placeholder {
    color: var(--text-2);
    opacity: 0.5;
}

.add-hint {
    font-size: 11px;
    color: var(--text-2);
    margin-top: 5px;
    line-height: 1.5;
    opacity: 0.7;
}

.add-hint code {
    background: var(--panel-2);
    padding: 1px 4px;
    font-size: 11px;
}

.add-divider {
    border-top: 1px solid var(--border);
    margin: 24px 0;
}

.add-target-section {
    margin-bottom: 20px;
}

.add-target-label {
    font-family: var(--display);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: var(--text-2);
    margin-bottom: 10px;
}

.add-target-fields {
    display: grid;
    grid-template-columns: 1fr 120px;
    gap: 12px;
}

.add-create-btn {
    display: block;
    width: 100%;
    padding: 12px;
    margin-top: 8px;
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: var(--void);
    background: var(--phosphor-dim);
    border: 1px solid var(--phosphor-dim);
    cursor: pointer;
    transition: all 0.2s;
}

.add-create-btn:hover {
    background: var(--phosphor-mid);
    border-color: var(--phosphor-mid);
}

.add-create-btn:disabled {
    opacity: 0.5;
    cursor: wait;
}

.add-error {
    margin-top: 12px;
    padding: 8px 12px;
    background: rgba(204, 51, 51, 0.08);
    border: 1px solid rgba(204, 51, 51, 0.3);
    color: #f66;
    font-size: 12px;
    font-family: var(--mono);
}

/* Guide column */

.add-guide-block {
    margin-bottom: 16px;
}

.add-guide-title {
    font-family: var(--display);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 2px;
    text-transform: uppercase;
    color: var(--phosphor-dim);
    margin-bottom: 14px;
}

.add-example {
    background: var(--void);
    border: 1px solid var(--border);
    padding: 12px 16px;
    margin-bottom: 14px;
    font-family: var(--mono);
    font-size: 13px;
}

.add-ex-row {
    display: flex;
    gap: 12px;
    padding: 2px 0;
}

.add-ex-k {
    color: var(--text-2);
    min-width: 55px;
    font-size: 10px;
    letter-spacing: 1px;
    padding-top: 2px;
}

.add-ex-v {
    color: var(--phosphor-mid);
}

.add-prose {
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.7;
    color: var(--text-1);
}

.add-prose code, .add-tips code, .add-steps code {
    background: var(--panel-2);
    padding: 1px 4px;
    font-size: 11px;
}

.add-prose strong, .add-tips strong, .add-steps strong {
    color: var(--text-0);
    font-weight: 500;
}

.add-steps {
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.7;
    color: var(--text-1);
    padding-left: 18px;
    margin: 0;
}

.add-steps li {
    margin-bottom: 14px;
}

.add-code {
    background: var(--void);
    border: 1px solid var(--border);
    padding: 8px 12px;
    margin: 6px 0 0;
    font-family: var(--mono);
    font-size: 12px;
    color: var(--phosphor-mid);
    overflow-x: auto;
}

.add-tips {
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.7;
    color: var(--text-1);
    padding-left: 18px;
    margin: 0;
}

.add-tips li {
    margin-bottom: 8px;
}

/* ═══ ALERTS ═══ */

.toast-container {
    position: fixed;
    bottom: 24px;
    right: 24px;
    z-index: 10001;
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.toast {
    font-size: 18px;
    padding: 10px 16px;
    border: 1px solid var(--border);
    background: var(--panel);
    color: var(--text-0);
    box-shadow: 0 0 30px rgba(0, 0, 0, 0.6);
    animation: toast-in 0.3s ease-out;
    max-width: 360px;
    letter-spacing: 1px;
    text-transform: uppercase;
}

.toast.success { border-left: 3px solid var(--phosphor); }
.toast.error { border-left: 3px solid var(--red); }

/* ═══ LOADING ═══ */

.spinner {
    width: 14px;
    height: 14px;
    border: 2px solid var(--border);
    border-top-color: var(--phosphor);
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
    display: inline-block;
}

.skeleton {
    background: linear-gradient(90deg, var(--panel) 25%, var(--panel-2) 50%, var(--panel) 75%);
    background-size: 200% 100%;
    animation: shimmer 1.5s infinite;
    height: 16px;
}

/* ═══ ANIMATIONS ═══ */

@keyframes bar-sweep {
    0% { left: -50%; }
    100% { left: 120%; }
}

@keyframes logo-spin {
    to { transform: rotate(360deg); }
}

@keyframes pulse-led {
    0%, 100% { opacity: 1; box-shadow: 0 0 8px var(--phosphor), 0 0 20px var(--phosphor-glow); }
    50% { opacity: 0.7; box-shadow: 0 0 4px var(--phosphor), 0 0 10px var(--phosphor-glow); }
}

@keyframes panel-boot {
    0% { opacity: 0; transform: translateY(8px); border-color: transparent; }
    60% { border-color: var(--phosphor-dim); }
    100% { opacity: 1; transform: translateY(0); border-color: var(--border); }
}

@keyframes deploy-pulse {
    0%, 100% { box-shadow: 0 0 8px rgba(255, 160, 0, 0.1); }
    50% { box-shadow: 0 0 25px rgba(255, 160, 0, 0.3), inset 0 0 15px rgba(255, 160, 0, 0.05); }
}

@keyframes blink-cursor {
    0%, 100% { opacity: 1; }
    50% { opacity: 0; }
}

@keyframes alert-flash {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

@keyframes spin {
    to { transform: rotate(360deg); }
}

@keyframes shimmer {
    0% { background-position: 200% 0; }
    100% { background-position: -200% 0; }
}

@keyframes toast-in {
    from { opacity: 0; transform: translateY(12px); }
    to { opacity: 1; transform: translateY(0); }
}

/* ═══ RESPONSIVE ═══ */

@media (max-width: 1024px) {
    .add-page-grid { grid-template-columns: 1fr; max-width: 600px; }
}

@media (max-width: 768px) {
    .detail-grid { grid-template-columns: 1fr; }
    .detail-sidebar { position: static; }
    .analysis-grid { grid-template-columns: 1fr; }
    .svc-grid { grid-template-columns: 1fr; }
    .mission-title { display: none; }
    .mission-clock { font-size: 13px; }
    .add-panel { padding: 20px; }
    .add-target-fields { grid-template-columns: 1fr 100px; }
}

@media (max-width: 480px) {
    .add-target-fields { grid-template-columns: 1fr; }
    .add-panel { padding: 16px; }
    .add-input { font-size: 14px; }
}

</style>
</head>
<body>

<canvas id="rain"></canvas>

<div class="mission-bar">
    <a href="/" class="mission-logo">
        <svg class="logo-svg" width="28" height="28" viewBox="0 0 28 28" fill="none">
            <polygon points="8,4 8,24 24,14" fill="currentColor"/>
        </svg>
        <span>.do</span>
    </a>
% if (app->mode eq 'development') {
    <div class="dev-badge">DEV MODE</div>
% }
    <div class="mission-title">SERVICES</div>
    <a href="/docs" class="mission-link">DOCS</a>
    <div class="target-switch" id="target-switch"></div>
    <div class="mission-clock" id="mission-clock">--:--:--</div>
    <div id="git-badge" class="git-badge synced" onclick="gitPush()" title="Click to push">
        <span id="git-status">SYNCED</span>
    </div>
    <div id="health-badge" class="health-badge ok">
        <span id="health-status">...</span>
    </div>
</div>

<div class="main">
    <%= content %>
</div>

<div class="toast-container" id="toasts"></div>

<script>
function toast(msg, type = 'success') {
    const c = document.getElementById('toasts');
    const t = document.createElement('div');
    t.className = 'toast ' + type;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, 4000);
}

async function api(path, opts = {}) {
    const res = await fetch(path, opts);
    return res.json();
}

function esc(s) { return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

function renderDeploySteps(out, steps) {
    out.classList.add('visible');
    out.innerHTML = '';
    if (!Array.isArray(steps)) return;
    let anyFail = false;
    for (const step of steps) {
        const ok = (typeof step.success === 'boolean') ? step.success : step.success === 1;
        if (!ok) anyFail = true;
        const icon = ok ? '\u2713' : '\u2717';
        const cls = ok ? 'step-ok' : 'step-fail';
        const body = (step.output || '').replace(/\r\n?/g, '\n').replace(/\r/g, '');
        const firstLine = body.split('\n').find(l => l.trim().length) || '';
        const details = document.createElement('details');
        details.className = 'deploy-step';
        details.dataset.ok = ok ? '1' : '0';
        details.open = !ok;  // auto-expand failures
        details.innerHTML =
            '<summary><span class="' + cls + '">' + icon + '</span> ' +
            '<span class="step-label">' + esc(step.step) + '</span> ' +
            '<span style="color:var(--text-2)">' + esc(firstLine.slice(0, 140)) + '</span></summary>' +
            '<div class="step-body">' + esc(body || '(no output)') + '</div>';
        out.appendChild(details);
    }
    return anyFail;
}

async function loadHealth() {
    try {
        const d = await api('/health');
        const b = document.getElementById('health-badge');
        const s = document.getElementById('health-status');
        if (d.status === 'success') {
            const running = d.data.services.running;
            const total = d.data.services.total;
            if (running === total) {
                s.textContent = running + '/' + total + ' NOMINAL';
            } else {
                s.textContent = running + '/' + total + ' DEGRADED';
            }
            b.className = 'health-badge ' + (running === total ? 'ok' : 'down');
        }
    } catch(e) {}
}

function updateClock() {
    const now = new Date();
    const h = String(now.getHours()).padStart(2, '0');
    const m = String(now.getMinutes()).padStart(2, '0');
    const s = String(now.getSeconds()).padStart(2, '0');
    document.getElementById('mission-clock').textContent = h + ':' + m + ':' + s;
}

(function() {
    const canvas = document.getElementById('rain');
    if (!canvas || !canvas.getContext) return;
    const ctx = canvas.getContext('2d');
    function resize() { canvas.width = innerWidth; canvas.height = innerHeight; }
    resize();
    addEventListener('resize', resize);
    const chars = '01234567>|/<\\[]{}=+-:'.split('');
    const fs = 14;
    let cols, drops;
    function initDrops() {
        cols = Math.floor(canvas.width / fs);
        drops = Array(cols).fill(0).map(() => Math.random() * canvas.height / fs | 0);
    }
    initDrops();
    addEventListener('resize', initDrops);
    setInterval(() => {
        ctx.fillStyle = 'rgba(1, 10, 1, 0.04)';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = 'rgba(0, 255, 65, 0.07)';
        ctx.font = fs + 'px IBM Plex Mono';
        for (let i = 0; i < cols; i++) {
            if (Math.random() > 0.975) {
                ctx.fillText(chars[Math.random() * chars.length | 0], i * fs, drops[i] * fs);
            }
            if (drops[i] * fs > canvas.height && Math.random() > 0.98) drops[i] = 0;
            drops[i]++;
        }
    }, 60);
})();

async function loadGitStatus() {
    try {
        const d = await api('/git/status');
        const b = document.getElementById('git-badge');
        const s = document.getElementById('git-status');
        if (d.status === 'success') {
            const n = d.data.unpushed;
            if (n > 0) {
                s.textContent = n + ' UNPUSHED \u2191';
                b.className = 'git-badge unpushed';
            } else {
                s.textContent = 'SYNCED';
                b.className = 'git-badge synced';
            }
        }
    } catch(e) {}
}

async function gitPush() {
    const b = document.getElementById('git-badge');
    const s = document.getElementById('git-status');
    if (b.classList.contains('synced')) return;
    s.textContent = 'PUSHING...';
    try {
        const d = await api('/git/push', { method: 'POST' });
        if (d.status === 'success') {
            toast('Push successful');
        } else {
            toast(d.message || 'Push failed', 'error');
        }
    } catch(e) {
        toast('Push error: ' + e.message, 'error');
    }
    loadGitStatus();
}

async function loadTargets() {
    try {
        const d = await api('/target');
        if (d.status !== 'success') return;
        const sw = document.getElementById('target-switch');
        const active = d.data.target;
        sw.innerHTML = '';
        d.data.available.forEach(t => {
            const btn = document.createElement('button');
            btn.className = 'target-btn' + (t === active ? ' active-' + t : '');
            btn.textContent = t;
            btn.onclick = () => switchTarget(t);
            sw.appendChild(btn);
        });
    } catch(e) {}
}

async function switchTarget(target) {
    await api('/target', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ target: target }),
    });
    loadTargets();
    location.reload();
}

loadHealth();
loadGitStatus();
loadTargets();
updateClock();
setInterval(loadHealth, 15000);
setInterval(loadGitStatus, 15000);
setInterval(updateClock, 1000);
</script>

<%= content_for 'scripts' %>

</body>
</html>


@@ dashboard.html.ep
% layout 'ops';
% title 'Dashboard';

<div class="page-header">
    <div class="page-title">SERVICE STATUS</div>
    <div class="page-subtitle">All subsystems monitored</div>
</div>

<div class="svc-grid" id="svc-grid">
    <div class="svc-card"><div class="skeleton" style="width:60%;margin-bottom:12px"></div><div class="skeleton" style="width:80%"></div></div>
    <div class="svc-card"><div class="skeleton" style="width:60%;margin-bottom:12px"></div><div class="skeleton" style="width:80%"></div></div>
    <div class="svc-card"><div class="skeleton" style="width:60%;margin-bottom:12px"></div><div class="skeleton" style="width:80%"></div></div>
</div>

% content_for scripts => begin
<script>
async function loadServices() {
    const d = await api('/services');
    if (d.status !== 'success') return;
    const grid = document.getElementById('svc-grid');
    grid.innerHTML = '';
    d.data.forEach((svc, idx) => {
        const running = svc.running;
        const isDev = svc.mode === 'development';
        const card = document.createElement('div');
        card.className = 'svc-card ' + (running ? 'running' : 'stopped') + (isDev ? ' dev-mode' : '');
        card.style.animationDelay = (idx * 0.08) + 's';
        const modeBadge = isDev
            ? '<span class="mode-badge dev">DEV</span>'
            : '<span class="mode-badge prod">LIVE</span>';
        const deployBtnClass = isDev ? 'btn btn-deploy-dev' : 'btn btn-deploy';
        const deployLabel = isDev ? 'DEPLOY DEV' : 'DEPLOY';
        card.innerHTML = `
            <div class="svc-header">
                <div class="svc-name"><a href="/ui/service/${svc.name}">${svc.name}</a>${modeBadge}${(() => { const sec = svc.secrets; if (!sec || sec.required === 0) return ''; const ok = sec.present === sec.required; return '<span class="badge ' + (ok ? 'badge-ok' : 'badge-warn') + '">secrets: ' + sec.present + '/' + sec.required + '</span>'; })()}</div>
                <div class="status-led ${running ? 'on' : 'off'}"></div>
            </div>
            <dl class="svc-meta">
                <dt>PORT</dt><dd>${svc.port || '\u2014'}</dd>
                <dt>PID</dt><dd>${svc.pid || '\u2014'}</dd>
                <dt>SHA</dt><dd>${svc.git_sha || '\u2014'}</dd>
                <dt>BRANCH</dt><dd>${svc.branch || '\u2014'}</dd>
                <dt>RUNNER</dt><dd>${svc.runner || '\u2014'}</dd>
            </dl>
            <div class="svc-actions">
                <a href="https://${svc.host || 'localhost'}" target="_blank" class="btn btn-tint btn-visit">VISIT</a>
                ${svc.docs ? '<a href="' + svc.docs + '" target="_blank" class="btn btn-tint btn-docs">DOCS</a>' : ''}
                ${svc.admin ? '<a href="' + svc.admin + '" target="_blank" class="btn btn-tint btn-admin">ADMIN</a>' : ''}
                <a href="/ui/service/${svc.name}#logs" class="btn">LOGS</a>
                <a href="/ui/service/${svc.name}" class="btn">CONFIG</a>
            </div>
            <div class="svc-actions svc-controls">
                <button class="btn btn-ctrl" onclick="svcAction('${svc.name}','start')"><svg class="btn-icon" viewBox="0 0 16 16"><polygon points="4,2 4,14 14,8"/></svg> START</button>
                <button class="btn btn-ctrl" onclick="svcAction('${svc.name}','restart')"><svg class="btn-icon" viewBox="0 0 16 16"><path d="M13,8A5,5 0 1,1 8,3" fill="none" stroke="currentColor" stroke-width="1.5"/><polygon points="8,0.5 8,5.5 11.5,3"/></svg> RESTART</button>
                <button class="btn btn-ctrl btn-tint btn-stop" onclick="svcAction('${svc.name}','stop')"><svg class="btn-icon" viewBox="0 0 16 16"><rect x="3" y="3" width="10" height="10"/></svg> STOP</button>
                <button class="${deployBtnClass}" onclick="deployService('${svc.name}', this, ${isDev})" id="deploy-btn-${svc.name.replace(/\./g,'_')}">
                    <svg class="btn-icon" viewBox="0 0 16 16"><polygon points="4,2 4,14 14,8"/></svg> ${deployLabel}
                </button>
            </div>
            <div class="deploy-output" id="deploy-out-${svc.name.replace(/\./g,'_')}"></div>
        `;
        grid.appendChild(card);
    });

    // Add "ADD SUBSYSTEM" link card
    const addCard = document.createElement('div');
    addCard.innerHTML = `<a href="/ui/add" class="add-subsystem-btn">+ ADD SERVICE</a>`;
    grid.appendChild(addCard);
}

async function svcAction(name, action) {
    try {
        const d = await api('/service/' + name + '/' + action, { method: 'POST' });
        if (d.status === 'success') {
            toast(name + ' ' + action + ' OK');
        } else {
            toast(d.message || action + ' failed', 'error');
        }
    } catch(e) {
        toast(action + ' error: ' + e.message, 'error');
    }
    loadServices();
}

async function deployService(name, btn, isDev = false) {
    const safeId = name.replace(/\./g, '_');
    const out = document.getElementById('deploy-out-' + safeId);
    btn.disabled = true;
    btn.classList.add('deploying');
    btn.innerHTML = '<span class="spinner"></span> IGNITION';
    out.classList.add('visible');
    out.innerHTML = '<span class="step-label">Initiating launch sequence...</span>\n';

    const endpoint = isDev ? '/service/' + name + '/deploy-dev' : '/service/' + name + '/deploy';
    try {
        const d = await api(endpoint, { method: 'POST' });
        renderDeploySteps(out, d.data && d.data.steps);
        if (d.status === 'success') {
            toast(name + ' launched successfully');
        } else {
            toast(d.message || 'Launch sequence failed', 'error');
        }
    } catch(e) {
        out.classList.add('visible');
        out.innerHTML = '<div class="step-fail">\u2717 ABORT: ' + esc(e.message) + '</div>';
        toast('Launch failed: ' + e.message, 'error');
    }

    btn.disabled = false;
    btn.classList.remove('deploying');
    btn.innerHTML = isDev ? 'DEPLOY DEV' : 'DEPLOY';
    setTimeout(loadServices, 2000);
}

loadServices();
setInterval(loadServices, 30000);
</script>
% end

@@ service_detail.html.ep
% layout 'ops';
% title $service_name;

<div class="page-header">
    <div class="page-title"><a href="/" class="back-link">&larr;</a> <%= $service_name %></div>
</div>

<div class="detail-grid">
    <div class="detail-sidebar">
        <div class="detail-info">
            <h2>
                <span class="status-led" id="svc-led"></span>
                <span id="svc-title"><%= $service_name %></span>
            </h2>
            <dl class="detail-meta" id="svc-meta">
                <dt>STATUS</dt><dd id="m-status">loading...</dd>
                <dt>MODE</dt><dd id="m-mode">&mdash;</dd>
                <dt>RUNNER</dt><dd id="m-runner">&mdash;</dd>
                <dt>PORT</dt><dd id="m-port">&mdash;</dd>
                <dt>PID</dt><dd id="m-pid">&mdash;</dd>
                <dt>SHA</dt><dd id="m-sha">&mdash;</dd>
                <dt>BRANCH</dt><dd id="m-branch">&mdash;</dd>
                <dt>REPO</dt><dd id="m-repo">&mdash;</dd>
            </dl>
            <button class="btn btn-deploy" id="deploy-btn" onclick="deploy()" style="width:100%;justify-content:center">
                <svg class="btn-icon" viewBox="0 0 16 16"><polygon points="4,2 4,14 14,8"/></svg> DEPLOY
            </button>
            <div class="lifecycle-row">
                <button class="btn btn-tint btn-docs"  id="update-btn"  onclick="lifecycle('update')"  title="git pull + cpanm + migrate, no restart"><svg class="btn-icon" viewBox="0 0 16 16"><path d="M8,2 L8,11 M4,7 L8,11 L12,7" fill="none" stroke="currentColor" stroke-width="1.5"/></svg> UPDATE</button>
                <button class="btn btn-tint btn-admin" id="migrate-btn" onclick="lifecycle('migrate')" title="Run bin/migrate only"><svg class="btn-icon" viewBox="0 0 16 16"><path d="M3,5 L8,5 M3,8 L13,8 M3,11 L10,11" fill="none" stroke="currentColor" stroke-width="1.5"/></svg> MIGRATE</button>
                <button class="btn btn-tint btn-stop"  id="restart-btn" onclick="lifecycle('restart')" title="ubic restart + port check"><svg class="btn-icon" viewBox="0 0 16 16"><path d="M13,8A5,5 0 1,1 8,3" fill="none" stroke="currentColor" stroke-width="1.5"/><polygon points="8,0.5 8,5.5 11.5,3"/></svg> RESTART</button>
            </div>
            <a id="visit-btn" href="#" target="_blank" rel="noopener"
               class="btn btn-tint btn-visit"
               style="width:100%;justify-content:center;margin-top:8px;display:none">
                VISIT &rarr;
            </a>
            <div class="secrets-panel" id="secrets-panel" style="display:none">
                <div class="section-title" style="margin-top:16px">SECRETS</div>
                <div id="secrets-content"></div>
            </div>
        </div>
    </div>

    <div class="detail-main">
        <div class="section-title">TERMINAL</div>
        <div class="log-viewer">
            <div class="log-toolbar">
                <div class="log-type-tabs" id="log-tabs"></div>
                <div class="log-search">
                    <input type="text" id="log-search-input" placeholder="> search..." onkeydown="if(event.key==='Enter')searchLogs()">
                    <button class="btn" onclick="searchLogs()">SEARCH</button>
                </div>
            </div>
            <div class="log-content" id="log-content"><span class="log-empty">Select log stream</span></div>
        </div>

        <div class="section-title" style="margin-top:24px">DIAGNOSTICS</div>
        <div id="analysis-container">
            <div class="analysis-card"><div class="skeleton" style="width:50%;margin-bottom:8px"></div><div class="skeleton" style="width:70%"></div></div>
        </div>

        <div class="section-title" style="margin-top:24px">CONFIG</div>
        <div class="config-editor" id="config-editor">
            <div class="config-toolbar">
                <div class="config-target-tabs" id="config-target-tabs"></div>
                <button class="btn" id="save-config-btn" onclick="saveConfig()">SAVE</button>
            </div>
            <div class="config-fields" id="config-fields">
                <span class="log-empty">Loading config...</span>
            </div>
        <div class="section-title" style="margin-top:24px">NGINX</div>
        <div class="config-editor">
            <div class="config-fields" id="nginx-status">
                <span class="log-empty">Loading nginx status...</span>
            </div>
        </div>
        </div>
    </div>
</div>

% content_for scripts => begin
<script>
const SVC = '<%= $service_name %>';
let currentLogType = null;

async function loadStatus() {
    const d = await api('/service/' + SVC + '/status');
    if (d.status !== 'success') return;
    const s = d.data;
    const isDev = s.mode === 'development';
    document.getElementById('svc-led').className = 'status-led ' + (s.running ? 'on' : 'off');
    document.getElementById('m-status').textContent = s.running ? 'ONLINE' : 'OFFLINE';
    document.getElementById('m-status').style.color = s.running ? 'var(--phosphor)' : 'var(--red)';
    document.getElementById('m-status').style.textShadow = s.running ? '0 0 8px var(--phosphor-glow)' : '0 0 8px var(--red-glow)';
    const modeEl = document.getElementById('m-mode');
    modeEl.textContent = s.mode || 'production';
    modeEl.style.color = isDev ? 'var(--dev)' : 'var(--phosphor-mid)';
    document.getElementById('m-runner').textContent = s.runner || 'hypnotoad';
    document.getElementById('m-port').textContent = s.port || '\u2014';
    document.getElementById('m-pid').textContent = s.pid || '\u2014';
    document.getElementById('m-sha').textContent = s.git_sha || '\u2014';
    document.getElementById('m-branch').textContent = s.branch || '\u2014';
    document.getElementById('m-repo').textContent = s.repo || '\u2014';

    const deployBtn = document.getElementById('deploy-btn');
    if (isDev) {
        deployBtn.className = 'btn btn-deploy-dev';
        deployBtn.setAttribute('onclick', 'deploy(true)');
        if (!deployBtn.classList.contains('deploying')) deployBtn.innerHTML = 'DEPLOY DEV';
    }

    const visit = document.getElementById('visit-btn');
    if (s.host && s.host !== 'localhost') {
        visit.href = 'https://' + s.host + '/';
        visit.style.display = '';
        visit.textContent = 'VISIT ' + s.host + ' \u2192';
    } else if (s.port) {
        visit.href = 'http://127.0.0.1:' + s.port + '/';
        visit.style.display = '';
        visit.textContent = 'VISIT :' + s.port + ' \u2192';
    } else {
        visit.style.display = 'none';
    }
    loadSecrets();
}

async function loadSecrets() {
    try {
        const d = await api('/service/' + SVC + '/secrets');
        if (d.status !== 'success') return;
        const panel = document.getElementById('secrets-panel');
        const content = document.getElementById('secrets-content');
        panel.style.display = '';
        let html = '';
        if (d.data.required && d.data.required.length > 0) {
            html += '<h3 class="secrets-heading">Required</h3><div class="secrets-list">';
            for (const key of d.data.required) {
                const isSet = d.data.present.includes(key);
                html += '<div class="secret-row" data-key="' + esc(key) + '">'
                    + '<span class="secret-key">' + esc(key) + '</span>'
                    + '<span class="secret-status ' + (isSet ? 'set' : 'missing') + '">' + (isSet ? 'SET' : 'MISSING') + '</span>'
                    + '<input type="password" class="secret-input" placeholder="' + (isSet ? '(keep existing)' : 'set value') + '" autocomplete="off">'
                    + '<button class="btn btn-sm" onclick="setSecret(\'' + esc(key) + '\', this)">Save</button>'
                    + (isSet ? '<button class="btn btn-sm btn-danger" onclick="deleteSecret(\'' + esc(key) + '\')">Del</button>' : '')
                    + '</div>';
            }
            html += '</div>';
        }
        const optKeys = Object.keys(d.data.optional || {});
        if (optKeys.length > 0) {
            html += '<details class="secrets-optional"><summary>Optional (' + optKeys.length + ')</summary><div class="secrets-list">';
            for (const key of optKeys.sort()) {
                const spec = d.data.optional[key] || {};
                const isSet = (d.data.optional_set || []).includes(key);
                const hint = spec.desc ? esc(spec.desc) : '';
                const def = spec['default'] ? ' (default: ' + esc(spec['default']) + ')' : '';
                html += '<div class="secret-row" data-key="' + esc(key) + '">'
                    + '<span class="secret-key">' + esc(key) + '</span>'
                    + '<span class="secret-hint">' + hint + def + '</span>'
                    + '<span class="secret-status ' + (isSet ? 'set' : 'default') + '">' + (isSet ? 'SET' : 'default') + '</span>'
                    + '<input type="password" class="secret-input" placeholder="' + (isSet ? '(keep existing)' : 'set value') + '" autocomplete="off">'
                    + '<button class="btn btn-sm" onclick="setSecret(\'' + esc(key) + '\', this)">Save</button>'
                    + (isSet ? '<button class="btn btn-sm btn-danger" onclick="deleteSecret(\'' + esc(key) + '\')">Del</button>' : '')
                    + '</div>';
            }
            html += '</div></details>';
        }
        if (!html) html = '<div class="secrets-none">No env keys declared in manifest.</div>';
        content.innerHTML = html;
    } catch(e) { /* silently ignore */ }
}

async function setSecret(key, btn) {
    const row = btn.closest('.secret-row');
    const input = row.querySelector('.secret-input');
    const value = input.value;
    if (!value) return;
    btn.disabled = true;
    try {
        const d = await api('/service/' + SVC + '/secrets', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({key: key, value: value})
        });
        if (d.status === 'success') { toast(key + ' saved'); loadSecrets(); }
        else { toast(d.message || 'Failed', 'error'); }
    } catch(e) { toast('Error: ' + e.message, 'error'); }
    btn.disabled = false;
    input.value = '';
}

async function deleteSecret(key) {
    if (!confirm('Delete ' + key + '?')) return;
    try {
        const d = await api('/service/' + SVC + '/secrets/delete', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({key: key})
        });
        if (d.status === 'success') { toast(key + ' deleted'); loadSecrets(); }
        else { toast(d.message || 'Failed', 'error'); }
    } catch(e) { toast('Error: ' + e.message, 'error'); }
}

let lastDeploySteps = null;

async function initLogTabs() {
    const d = await api('/services');
    if (d.status !== 'success') return;
    const svc = d.data.find(s => s.name === SVC);
    if (!svc) return;

    const tabs = document.getElementById('log-tabs');
    const logTypes = ['deploy', 'stdout', 'stderr', 'app', 'ubic'];
    tabs.innerHTML = '';
    logTypes.forEach(type => {
        const btn = document.createElement('button');
        btn.className = 'log-type-tab';
        btn.dataset.type = type;
        btn.textContent = type;
        btn.onclick = () => selectLogType(type, btn);
        tabs.appendChild(btn);
    });
    // default stderr on page load
    const stderrTab = tabs.querySelector('.log-type-tab[data-type="stderr"]');
    if (stderrTab) selectLogType('stderr', stderrTab);
}

async function selectLogType(type, btn) {
    currentLogType = type;
    document.querySelectorAll('.log-type-tab').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    if (type === 'deploy') {
        showDeployOutput();
    } else {
        await loadLogs(type);
    }
}

function showDeployOutput() {
    const content = document.getElementById('log-content');
    if (lastDeploySteps && lastDeploySteps.length) {
        renderDeploySteps(content, lastDeploySteps);
    } else {
        content.innerHTML = '<span class="log-empty">No deploys in this session yet. Press DEPLOY (or UPDATE/MIGRATE/RESTART when added) to see per-step output here.</span>';
    }
}

function activateDeployTab() {
    const tab = document.querySelector('.log-type-tab[data-type="deploy"]');
    if (tab) selectLogType('deploy', tab);
}

async function loadLogs(type, n = 200) {
    const content = document.getElementById('log-content');
    content.innerHTML = '<span class="spinner"></span> Loading...';
    const d = await api('/service/' + SVC + '/logs?type=' + type + '&n=' + n);
    if (d.status === 'error') {
        content.innerHTML = '<span class="log-empty">' + d.message + '</span>';
        return;
    }
    if (!d.data.lines || d.data.lines.length === 0) {
        content.innerHTML = '<span class="log-empty">No log entries</span>';
        return;
    }
    content.innerHTML = d.data.lines.map(colorLine).join('\n');
    content.scrollTop = content.scrollHeight;
}

async function searchLogs() {
    const q = document.getElementById('log-search-input').value.trim();
    if (!q) { if (currentLogType) loadLogs(currentLogType); return; }
    const type = currentLogType || 'stderr';
    const content = document.getElementById('log-content');
    content.innerHTML = '<span class="spinner"></span> Searching...';
    const d = await api('/service/' + SVC + '/logs/search?type=' + type + '&q=' + encodeURIComponent(q) + '&n=100');
    if (d.status === 'error') {
        content.innerHTML = '<span class="log-empty">' + d.message + '</span>';
        return;
    }
    if (!d.data.matches || d.data.matches.length === 0) {
        content.innerHTML = '<span class="log-empty">No matches for "' + escHtml(q) + '"</span>';
        return;
    }
    content.innerHTML = d.data.matches.map(m => {
        const hl = m.text.replace(new RegExp('(' + escRegex(q) + ')', 'gi'), '<span class="log-highlight">$1</span>');
        return '<span class="log-info">' + m.line + ':</span> ' + colorLine(hl);
    }).join('\n');
}

function colorLine(line) {
    if (/\b(error|fatal|die|exception)\b/i.test(line)) return '<span class="log-error">' + escHtml(line) + '</span>';
    if (/\bwarn(ing)?\b/i.test(line)) return '<span class="log-warn">' + escHtml(line) + '</span>';
    return escHtml(line);
}

function escHtml(s) {
    if (s.includes('<span')) return s;
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function escRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

async function loadAnalysis() {
    const container = document.getElementById('analysis-container');
    const d = await api('/service/' + SVC + '/logs/analyse');
    if (d.status === 'error') {
        container.innerHTML = '<div class="analysis-card"><span class="log-empty">' + d.message + '</span></div>';
        return;
    }
    const a = d.data;
    let html = '';

    html += '<div class="analysis-grid">';
    html += '<div class="analysis-card"><h3>HTTP STATUS CODES</h3>';
    if (Object.keys(a.statusCodes || {}).length > 0) {
        html += '<div class="status-code-grid">';
        Object.entries(a.statusCodes).sort().forEach(([code, count]) => {
            const cls = code < 300 ? 's2xx' : code < 400 ? 's3xx' : code < 500 ? 's4xx' : 's5xx';
            html += '<div class="status-code-chip ' + cls + '">' + code + ' <span class="count">\u00d7' + count + '</span></div>';
        });
        html += '</div>';
    } else {
        html += '<span class="log-empty">No status codes found</span>';
    }
    html += '</div>';

    html += '<div class="analysis-card"><h3>ERRORS</h3>';
    if (a.errors && a.errors.length > 0) {
        a.errors.slice(0, 8).forEach(e => {
            html += '<div class="stat-row"><span class="stat-label">' + escHtml(e.pattern.substring(0,60)) + '</span><span class="stat-value error">\u00d7' + e.count + '</span></div>';
        });
    } else {
        html += '<span class="stat-value ok" style="font-size: 17px">No errors detected</span>';
    }
    html += '</div>';

    html += '<div class="analysis-card"><h3>WARNINGS</h3>';
    if (a.warnings && a.warnings.length > 0) {
        a.warnings.slice(0, 8).forEach(w => {
            html += '<div class="stat-row"><span class="stat-label">' + escHtml(w.pattern.substring(0,60)) + '</span><span class="stat-value warn">\u00d7' + w.count + '</span></div>';
        });
    } else {
        html += '<span class="stat-value ok" style="font-size: 17px">No warnings detected</span>';
    }
    html += '</div>';

    html += '<div class="analysis-card"><h3>SUMMARY</h3>';
    html += '<div class="stat-row"><span class="stat-label">Period</span><span class="stat-value">' + a.period + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Requests tracked</span><span class="stat-value">' + (a.requestCount || 0) + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Error patterns</span><span class="stat-value ' + (a.errors.length ? 'error' : 'ok') + '">' + a.errors.length + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Warning patterns</span><span class="stat-value ' + (a.warnings.length ? 'warn' : 'ok') + '">' + a.warnings.length + '</span></div>';
    html += '</div>';

    html += '</div>';
    container.innerHTML = html;
}

async function deploy(isDev = false) {
    const btn = document.getElementById('deploy-btn');
    activateDeployTab();
    const out = document.getElementById('log-content');
    btn.disabled = true;
    btn.classList.add('deploying');
    btn.innerHTML = '<span class="spinner"></span> IGNITION';
    out.innerHTML = '<span class="step-label">Initiating launch sequence...</span>';

    const endpoint = isDev ? '/service/' + SVC + '/deploy-dev' : '/service/' + SVC + '/deploy';
    try {
        const d = await api(endpoint, { method: 'POST' });
        lastDeploySteps = (d.data && d.data.steps) || [];
        renderDeploySteps(out, lastDeploySteps);
        if (d.status === 'success') {
            toast(SVC + ' launched successfully');
        } else {
            toast(d.message || 'Launch sequence failed', 'error');
        }
    } catch(e) {
        out.innerHTML = '<div class="step-fail">\u2717 ABORT: ' + esc(e.message) + '</div>';
        toast('Launch error: ' + e.message, 'error');
    }

    btn.disabled = false;
    btn.classList.remove('deploying');
    btn.innerHTML = isDev ? 'DEPLOY DEV' : 'DEPLOY';
    loadStatus();
}

async function lifecycle(action) {
    const btn = document.getElementById(action + '-btn');
    activateDeployTab();
    const out = document.getElementById('log-content');
    btn.disabled = true;
    const original = btn.textContent;
    btn.innerHTML = '<span class="spinner"></span> ' + action.toUpperCase();
    out.innerHTML = '<span class="step-label">Running ' + action + '...</span>';

    try {
        const d = await api('/service/' + SVC + '/' + action, { method: 'POST' });
        lastDeploySteps = (d.data && d.data.steps) || [];
        renderDeploySteps(out, lastDeploySteps);
        if (d.status === 'success') {
            toast(SVC + ' ' + action + ' ok');
        } else {
            toast(d.message || (action + ' failed'), 'error');
        }
    } catch(e) {
        out.innerHTML = '<div class="step-fail">\u2717 ABORT: ' + esc(e.message) + '</div>';
        toast(action + ' error: ' + e.message, 'error');
    }

    btn.disabled = false;
    btn.textContent = original;
    loadStatus();
}

let svcConfig = null;
let currentTarget = null;

async function loadConfig() {
    const d = await api('/service/' + SVC + '/config');
    if (d.status !== 'success') return;
    svcConfig = d.data;

    const tabs = document.getElementById('config-target-tabs');
    const targets = Object.keys(svcConfig.targets || {});
    tabs.innerHTML = '';
    targets.forEach((t, i) => {
        const btn = document.createElement('button');
        btn.className = 'config-target-tab' + (i === 0 ? ' active' : '');
        btn.textContent = t;
        btn.onclick = () => {
            document.querySelectorAll('.config-target-tab').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentTarget = t;
            renderConfigFields(t);
        };
        tabs.appendChild(btn);
    });

    // Add "+" button to show inline input for new target
    const addBtn = document.createElement('button');
    addBtn.className = 'config-target-tab';
    addBtn.textContent = '+';
    addBtn.onclick = () => {
        if (document.getElementById('new-target-input')) return;
        const input = document.createElement('input');
        input.id = 'new-target-input';
        input.className = 'config-input';
        input.placeholder = 'staging';
        input.style.cssText = 'width:80px;padding:3px 8px;font-size: 16px';
        input.onkeydown = (e) => {
            if (e.key === 'Enter') {
                const name = input.value.trim();
                if (!name || svcConfig.targets[name]) return;
                svcConfig.targets[name] = { port: '', runner: 'hypnotoad', env: {}, logs: {} };
                loadConfig();
            }
            if (e.key === 'Escape') input.remove();
        };
        tabs.insertBefore(input, addBtn);
        input.focus();
    };
    tabs.appendChild(addBtn);

    currentTarget = targets[0] || 'live';
    renderConfigFields(currentTarget);
}

function renderConfigFields(targetName) {
    const fields = document.getElementById('config-fields');
    const t = svcConfig.targets[targetName] || {};
    let html = '';

    html += '<div class="config-section-label">SERVICE</div>';
    html += configRow('REPO', 'cfg-repo', svcConfig.repo || '');
    html += configRow('BRANCH', 'cfg-branch', svcConfig.branch || 'master');
    html += configRow('BIN', 'cfg-bin', svcConfig.bin || '');
    html += configRow('PERLBREW', 'cfg-perlbrew', svcConfig.perlbrew || '');

    html += '<div class="config-section-label">TARGET: ' + targetName.toUpperCase() + '</div>';
    html += configRow('HOST', 'cfg-host', t.host || '');
    html += configRow('PORT', 'cfg-port', t.port || '');
    html += configRow('RUNNER', 'cfg-runner', t.runner || 'hypnotoad');
    html += configRow('DOCS', 'cfg-docs', t.docs || '');
    html += configRow('ADMIN', 'cfg-admin', t.admin || '');

    html += '<div class="config-section-label">ENVIRONMENT</div>';
    const env = t.env || {};
    Object.entries(env).forEach(([k, v]) => {
        html += configRow(k, 'cfg-env-' + k, v, true);
    });
    html += '<div class="config-row"><span class="config-label"></span><button class="btn" onclick="addEnvVar()" style="font-size: 13px">+ ADD VAR</button></div>';

    fields.innerHTML = html;
    fields.querySelectorAll('.config-input').forEach(el => {
        el.addEventListener('input', markConfigDirty);
    });
}

function markConfigDirty() {
    const btn = document.getElementById('save-config-btn');
    if (btn) btn.className = 'btn btn-save-dirty';
}

function configRow(label, id, value, isSecret) {
    const cls = isSecret ? 'config-input secret' : 'config-input';
    return '<div class="config-row"><span class="config-label">' + label + '</span><input class="' + cls + '" id="' + id + '" value="' + escHtml(String(value)) + '" data-field="' + label + '"></div>';
}

function addEnvVar() {
    const existing = document.getElementById('new-env-row');
    if (existing) { existing.querySelector('input').focus(); return; }
    const fields = document.getElementById('config-fields');
    const row = document.createElement('div');
    row.className = 'config-row';
    row.id = 'new-env-row';
    row.innerHTML = '<input class="config-input" id="new-env-key" placeholder="VAR_NAME" style="max-width:120px">' +
        '<input class="config-input secret" id="new-env-val" placeholder="value">';
    fields.insertBefore(row, fields.lastElementChild);
    const keyInput = document.getElementById('new-env-key');
    keyInput.focus();
    keyInput.onkeydown = (e) => {
        if (e.key === 'Enter') {
            const key = keyInput.value.trim().toUpperCase();
            if (!key) return;
            if (!svcConfig.targets[currentTarget].env) svcConfig.targets[currentTarget].env = {};
            svcConfig.targets[currentTarget].env[key] = document.getElementById('new-env-val').value;
            renderConfigFields(currentTarget);
        }
        if (e.key === 'Escape') row.remove();
    };
}

async function saveConfig() {
    // Read values from fields
    svcConfig.repo = document.getElementById('cfg-repo').value;
    svcConfig.branch = document.getElementById('cfg-branch').value;
    svcConfig.bin = document.getElementById('cfg-bin').value;
    const pb = document.getElementById('cfg-perlbrew').value;
    if (pb) svcConfig.perlbrew = pb; else delete svcConfig.perlbrew;

    const t = svcConfig.targets[currentTarget];
    t.host = document.getElementById('cfg-host').value;
    t.port = parseInt(document.getElementById('cfg-port').value) || '';
    t.runner = document.getElementById('cfg-runner').value;
    const docs = document.getElementById('cfg-docs').value.trim();
    const admin = document.getElementById('cfg-admin').value.trim();
    if (docs) t.docs = docs; else delete t.docs;
    if (admin) t.admin = admin; else delete t.admin;

    // Read env vars
    const env = {};
    document.querySelectorAll('.config-input.secret').forEach(input => {
        const key = input.dataset.field;
        if (key) env[key] = input.value;
    });
    t.env = env;

    try {
        const d = await api('/service/' + SVC + '/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(svcConfig),
        });
        if (d.status === 'success') {
            toast('Config saved');
            const sb = document.getElementById('save-config-btn');
            if (sb) sb.className = 'btn';
            loadGitStatus();
        } else {
            toast(d.message || 'Save failed', 'error');
        }
    } catch(e) {
        toast('Save error: ' + e.message, 'error');
    }
}

async function loadNginxStatus() {
    const container = document.getElementById('nginx-status');
    const d = await api('/service/' + SVC + '/nginx');
    if (d.status !== 'success') {
        container.innerHTML = '<span class="log-empty">' + (d.message || 'Failed to load') + '</span>';
        return;
    }
    const n = d.data;
    let html = '';
    html += '<div class="stat-row"><span class="stat-label">Host</span><span class="stat-value">' + n.host + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Config</span><span class="stat-value ' + (n.config_exists ? 'ok' : 'error') + '">' + (n.config_exists ? 'EXISTS' : 'MISSING') + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">Enabled</span><span class="stat-value ' + (n.enabled ? 'ok' : 'error') + '">' + (n.enabled ? 'YES' : 'NO') + '</span></div>';
    html += '<div class="stat-row"><span class="stat-label">SSL</span><span class="stat-value ' + (n.ssl ? 'ok' : 'warn') + '">' + (n.ssl ? 'ACTIVE' : 'NONE') + '</span></div>';
    html += '<div style="display:flex;gap:8px;margin-top:12px">';
    html += '<button class="btn btn-deploy" onclick="nginxSetup()" style="flex:1;justify-content:center">SETUP NGINX</button>';
    if (!n.ssl) {
        html += '<button class="btn btn-tint btn-docs" onclick="nginxCertbot()" style="flex:1;justify-content:center">GET SSL CERT</button>';
    }
    html += '</div>';
    html += '<div class="deploy-output" id="nginx-out"></div>';
    container.innerHTML = html;
}

async function nginxSetup() {
    const out = document.getElementById('nginx-out');
    out.classList.add('visible');
    out.innerHTML = '<span class="step-label">Setting up nginx...</span>\n';
    try {
        const d = await api('/service/' + SVC + '/nginx/setup', { method: 'POST' });
        out.innerHTML = '';
        if (d.data && d.data.steps) {
            d.data.steps.forEach(step => {
                const ok = (typeof step.success === 'boolean') ? step.success : step.success;
                const cls = ok ? 'step-ok' : 'step-fail';
                const icon = ok ? '\u2713' : '\u2717';
                out.innerHTML += '<span class="' + cls + '">' + icon + '</span> <span class="step-label">' + step.step + '</span>  ' + (step.output||'').substring(0, 200) + '\n';
            });
        }
        toast(d.status === 'success' ? 'Nginx configured' : (d.message || 'Setup failed'), d.status === 'success' ? 'success' : 'error');
        loadNginxStatus();
    } catch(e) {
        out.innerHTML += '<span class="step-fail">\u2717 ' + e.message + '</span>\n';
        toast('Nginx setup error', 'error');
    }
}

async function nginxCertbot() {
    const out = document.getElementById('nginx-out');
    out.classList.add('visible');
    out.innerHTML = '<span class="step-label">Requesting SSL certificate...</span>\n';
    try {
        const d = await api('/service/' + SVC + '/nginx/certbot', { method: 'POST' });
        if (d.status === 'success') {
            toast('SSL certificate obtained');
            out.innerHTML += '<span class="step-ok">\u2713 Certificate installed</span>\n';
        } else {
            toast(d.message || 'Certbot failed', 'error');
            out.innerHTML += '<span class="step-fail">\u2717 ' + (d.data?.output || d.message) + '</span>\n';
        }
        loadNginxStatus();
    } catch(e) {
        toast('Certbot error', 'error');
    }
}

loadStatus();
initLogTabs();
loadAnalysis();
loadConfig();
loadNginxStatus();
setInterval(loadStatus, 10000);
</script>
% end

@@ docs.html.ep
% layout 'ops';
% title 'Docs';

<div class="page-header">
    <div class="page-title"><a href="/" class="back-link">&larr;</a> DOCS</div>
</div>

<article class="doc-panel">
<%== $doc_html %>
</article>

<style>
.doc-panel {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 32px 40px;
    max-width: 880px;
    margin: 0 auto;
    color: var(--text-0);
    font-family: var(--mono);
    font-size: 17px;
    line-height: 1.65;
}
.doc-panel h1, .doc-panel h2, .doc-panel h3 {
    font-family: var(--display);
    color: var(--phosphor);
    letter-spacing: 2px;
    text-transform: uppercase;
    margin: 28px 0 14px;
}
.doc-panel h1 { font-size: 26px; border-bottom: 1px solid var(--border-hi); padding-bottom: 10px; margin-top: 0; }
.doc-panel h2 { font-size: 19px; color: var(--amber); }
.doc-panel h3 { font-size: 16px; color: var(--cyan); }
.doc-panel p  { margin: 10px 0; }
.doc-panel ul, .doc-panel ol { margin: 10px 0 10px 22px; }
.doc-panel li { margin: 4px 0; }
.doc-panel code {
    background: var(--panel-3);
    color: var(--amber);
    padding: 1px 6px;
    border-radius: 2px;
    font-size: 16px;
}
.doc-panel pre {
    background: var(--void);
    border: 1px solid var(--border);
    padding: 14px 16px;
    overflow-x: auto;
    margin: 12px 0;
}
.doc-panel pre code {
    background: transparent;
    color: var(--text-0);
    padding: 0;
}
.doc-panel table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 14px; }
.doc-panel th { text-align: left; padding: 8px 12px; border-bottom: 2px solid var(--border-hi); color: var(--phosphor-mid); font-weight: 600; letter-spacing: 1px; font-size: 12px; }
.doc-panel td { padding: 6px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
.doc-panel tr:last-child td { border-bottom: none; }
.doc-panel a { color: var(--cyan); text-decoration: none; border-bottom: 1px dotted var(--cyan); }
.doc-panel a:hover { color: var(--phosphor); border-bottom-color: var(--phosphor); }
.doc-panel hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
.doc-panel strong { color: var(--phosphor-mid); font-weight: 600; }
.doc-panel em { color: var(--text-0); font-style: italic; }
</style>

@@ add_subsystem.html.ep
% layout 'ops';
% title 'Add Service';

<div class="page-header">
    <div class="page-title"><a href="/" class="back-link">&larr;</a> Add Service</div>
</div>

<div class="add-page">
    <div class="add-page-grid">

        <!-- ── Form ── -->
        <div class="add-page-form">
            <div class="add-panel">
                <div class="add-field">
                    <label class="add-label" for="add-name">Service name</label>
                    <input class="add-input" id="add-name" placeholder="pizza.web" autocomplete="off" spellcheck="false">
                    <div class="add-hint"><code>group.service</code> format &mdash; the group drives ubic, nginx, and repo naming</div>
                </div>

                <div class="add-field">
                    <label class="add-label" for="add-repo">Repo path</label>
                    <input class="add-input" id="add-repo" placeholder="/home/s3/web.pizza.do" autocomplete="off" spellcheck="false">
                    <div class="add-hint">Where the code lives on disk (or will live after <code>321 install</code>)</div>
                </div>

                <div class="add-field">
                    <label class="add-label" for="add-branch">Branch</label>
                    <input class="add-input" id="add-branch" value="master" autocomplete="off" spellcheck="false">
                </div>

                <div class="add-divider"></div>

                <div class="add-target-section">
                    <div class="add-target-label">Dev</div>
                    <div class="add-target-fields">
                        <div class="add-field">
                            <label class="add-label-sm" for="add-dev-host">Host</label>
                            <input class="add-input" id="add-dev-host" placeholder="pizza.do.dev" autocomplete="off" spellcheck="false">
                        </div>
                        <div class="add-field">
                            <label class="add-label-sm" for="add-dev-port">Port</label>
                            <input class="add-input" id="add-dev-port" placeholder="9500" autocomplete="off" inputmode="numeric">
                        </div>
                    </div>
                </div>

                <div class="add-target-section">
                    <div class="add-target-label">Live</div>
                    <div class="add-target-fields">
                        <div class="add-field">
                            <label class="add-label-sm" for="add-live-host">Host</label>
                            <input class="add-input" id="add-live-host" placeholder="pizza.do" autocomplete="off" spellcheck="false">
                        </div>
                        <div class="add-field">
                            <label class="add-label-sm" for="add-live-port">Port</label>
                            <input class="add-input" id="add-live-port" placeholder="9500" autocomplete="off" inputmode="numeric">
                        </div>
                    </div>
                </div>

                <button class="add-create-btn" id="create-btn" onclick="createSubsystem()">
                    Register Service
                </button>
                <div id="create-error" class="add-error" style="display:none"></div>
            </div>
        </div>

        <!-- ── Guide ── -->
        <div class="add-page-guide">

            <div class="add-panel add-guide-block">
                <div class="add-guide-title">Example</div>
                <div class="add-example">
                    <div class="add-ex-row"><span class="add-ex-k">NAME</span><span class="add-ex-v">pizza.web</span></div>
                    <div class="add-ex-row"><span class="add-ex-k">REPO</span><span class="add-ex-v">/home/s3/web.pizza.do</span></div>
                    <div class="add-ex-row"><span class="add-ex-k">BRANCH</span><span class="add-ex-v">master</span></div>
                    <div class="add-ex-row"><span class="add-ex-k">DEV</span><span class="add-ex-v">pizza.do.dev :9500</span></div>
                    <div class="add-ex-row"><span class="add-ex-k">LIVE</span><span class="add-ex-v">pizza.do :9500</span></div>
                </div>
                <p class="add-prose">
                    Type a name and the other fields auto-fill. The <strong>group</strong> (<code>pizza</code>)
                    sets the repo directory, ubic service tree, and nginx config.
                    Dev hosts use a <code>.dev</code> suffix with mkcert for local SSL.
                </p>
            </div>

            <div class="add-panel add-guide-block">
                <div class="add-guide-title">After registering</div>
                <ol class="add-steps">
                    <li>
                        <strong>Add a manifest</strong> to your repo &mdash; create <code>321.yml</code> at the root:
                        <pre class="add-code">name: pizza.web
entry: bin/app.pl
runner: hypnotoad</pre>
                    </li>
                    <li>
                        <strong>Install</strong> from the terminal:
                        <pre class="add-code">321 install pizza.web</pre>
                        Clones the repo, installs deps, sets up ubic + nginx + SSL, starts the service.
                    </li>
                    <li><strong>Set secrets</strong> if the manifest declares <code>env_required</code> &mdash; use the secrets panel on the service page.</li>
                    <li><strong>Check the dashboard</strong> &mdash; green LED means it&rsquo;s running.</li>
                </ol>
            </div>

            <div class="add-panel add-guide-block">
                <div class="add-guide-title">Tips</div>
                <ul class="add-tips">
                    <li><strong>Ports</strong> &mdash; check the dashboard to see what&rsquo;s already in use.</li>
                    <li><strong>Naming</strong> &mdash; keep the group short and lowercase. It appears everywhere.</li>
                    <li><strong>Dev parity</strong> &mdash; dev gets the same nginx + SSL as live. Run <code>321 hosts</code> after install.</li>
                    <li><strong>No bin/runner field?</strong> &mdash; those come from <code>321.yml</code> in the service repo.</li>
                </ul>
            </div>

        </div>
    </div>
</div>

%= content_for 'scripts' => begin
<script>
const nameInput = document.getElementById('add-name');
const repoInput = document.getElementById('add-repo');
const devHostInput = document.getElementById('add-dev-host');
const liveHostInput = document.getElementById('add-live-host');
const devPortInput = document.getElementById('add-dev-port');
const livePortInput = document.getElementById('add-live-port');

nameInput.addEventListener('input', function() {
    const name = this.value.trim();
    const group = name.split('.')[0];
    if (group && !repoInput.dataset.touched) {
        repoInput.value = '/home/s3/web.' + group + '.do';
    }
    if (group && !devHostInput.dataset.touched) {
        devHostInput.value = group + '.do.dev';
    }
    if (group && !liveHostInput.dataset.touched) {
        liveHostInput.value = group + '.do';
    }
});

devPortInput.addEventListener('input', function() {
    if (!livePortInput.dataset.touched) {
        livePortInput.value = this.value;
    }
});

[repoInput, devHostInput, liveHostInput, livePortInput].forEach(el => {
    el.addEventListener('input', function() { this.dataset.touched = '1'; });
});

async function createSubsystem() {
    const errEl = document.getElementById('create-error');
    errEl.style.display = 'none';

    const name = nameInput.value.trim();
    if (!name) { showError('Enter a service name'); return; }
    if (!/^[a-z0-9]+\.[a-z0-9]+$/.test(name)) {
        showError('Name must be group.service (e.g. pizza.web)');
        return;
    }

    const repo = repoInput.value.trim();
    if (!repo) { showError('Enter a repo path'); return; }

    const branch = document.getElementById('add-branch').value.trim() || 'master';
    const devHost = devHostInput.value.trim();
    const devPort = devPortInput.value.trim();
    const liveHost = liveHostInput.value.trim();
    const livePort = livePortInput.value.trim();

    if (!devPort && !livePort) { showError('Enter at least one port'); return; }

    const data = {
        name: name,
        repo: repo,
        branch: branch,
        targets: {},
    };

    if (devPort) {
        data.targets.dev = {
            host: devHost || 'localhost',
            port: parseInt(devPort, 10),
            runner: 'morbo',
            env: {},
            logs: {},
        };
    }
    if (livePort) {
        data.targets.live = {
            host: liveHost || 'localhost',
            port: parseInt(livePort, 10),
            runner: 'hypnotoad',
            env: {},
            logs: {},
        };
    }

    const btn = document.getElementById('create-btn');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> CREATING...';

    try {
        const d = await api('/services/create', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data),
        });
        if (d.status === 'success') {
            window.location.href = '/ui/service/' + name;
        } else {
            showError(d.message || 'Create failed');
        }
    } catch(e) {
        showError('Error: ' + e.message);
    }

    btn.disabled = false;
    btn.textContent = 'CREATE';
}

function showError(msg) {
    const el = document.getElementById('create-error');
    el.textContent = msg;
    el.style.display = 'block';
}
</script>
% end

