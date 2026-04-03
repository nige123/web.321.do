#!/usr/bin/env perl

# 321.do — standalone deploy and log analysis service
# See CLAUDE.md for full specification

use Mojolicious::Lite -signatures;
use Mojo::File qw(curfile);

app->config(hypnotoad => {listen => ['http://*:9999']});

my $app_home = curfile->dirname->dirname;
use lib curfile->dirname->dirname->child('lib')->to_string;

use Deploy::Config;
use Deploy::Service;
use Deploy::Logs;

# --- Config ---

my $config = Deploy::Config->new(app_home => $app_home);

my $service_mgr = Deploy::Service->new(
    config => $config,
    log    => app->log,
);

my $logs_mgr = Deploy::Logs->new(
    config => $config,
);

# --- Helpers ---

helper config  => sub { $config };
helper svc_mgr => sub { $service_mgr };
helper log_mgr => sub { $logs_mgr };

helper json_response => sub ($c, $status, $message, $data = {}) {
    $c->render(json => { status => $status, message => $message, data => $data });
};

helper validate_service => sub ($c, $name) {
    unless ($config->service($name)) {
        $c->json_response(error => "Unknown service: $name");
        return 0;
    }
    return 1;
};

# --- Auth ---

under '/' => sub ($c) {
    my $path = $c->req->url->path->to_string;

    # /health is public
    return 1 if $path eq '/health';

    # Skip auth in development mode
    return 1 if app->mode eq 'development';

    my $url_userinfo = $c->req->url->to_abs->userinfo // '';
    if ($url_userinfo eq '321:kaizen') {
        return 1;
    }

    if (my $userinfo = $c->req->headers->authorization) {
        if ($userinfo =~ /^Basic\s+(.+)$/) {
            require MIME::Base64;
            my $decoded = MIME::Base64::decode_base64($1);
            if ($decoded eq '321:kaizen') {
                return 1;
            }
        }
    }

    $c->res->headers->www_authenticate('Basic realm="321.do"');
    $c->res->code(401);
    $c->render(text => 'Authentication required', status => 401);
    return 0;
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
    my $services = $service_mgr->all_status;
    $c->json_response(success => scalar(@$services) . ' services registered', $services);
};

# Service status
get '/service/#name/status' => sub ($c) {
    my $name = $c->param('name');
    return unless $c->validate_service($name);

    my $status = $service_mgr->status($name);
    $c->json_response(success => "Status for $name", $status);
};

# Deploy a service
post '/service/#name/deploy' => sub ($c) {
    my $name = $c->param('name');
    return unless $c->validate_service($name);

    app->log->info("Deploy requested for $name");
    my $result = $service_mgr->deploy($name);
    $c->render(json => $result);
};

# Tail logs
get '/service/#name/logs' => sub ($c) {
    my $name = $c->param('name');
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
    my $name = $c->param('name');
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
    my $name = $c->param('name');
    return unless $c->validate_service($name);

    my $n = $c->param('n') // 1000;
    $n = int($n);
    $n = 10000 if $n > 10000;

    my $result = $logs_mgr->analyse($name, $n);
    $c->render(json => $result);
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

app->start;

__DATA__

@@ layouts/ops.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><%= title %> — 321.do</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600;700&family=DM+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root {
    --bg-0: #0a0a0b;
    --bg-1: #111113;
    --bg-2: #19191d;
    --bg-3: #222228;
    --border: #2a2a32;
    --border-hi: #3a3a45;
    --text-0: #e8e8ed;
    --text-1: #a0a0b0;
    --text-2: #65657a;
    --green: #00e676;
    --green-dim: #00c853;
    --green-glow: rgba(0, 230, 118, 0.15);
    --red: #ff1744;
    --red-dim: #d50000;
    --red-glow: rgba(255, 23, 68, 0.12);
    --amber: #ffab00;
    --amber-glow: rgba(255, 171, 0, 0.12);
    --blue: #448aff;
    --blue-glow: rgba(68, 138, 255, 0.12);
    --mono: 'JetBrains Mono', 'Menlo', monospace;
    --sans: 'DM Sans', system-ui, sans-serif;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
    background: var(--bg-0);
    color: var(--text-0);
    font-family: var(--sans);
    font-size: 16px;
    line-height: 1.5;
    min-height: 100vh;
    overflow-x: hidden;
}

/* Scanline overlay */
body::after {
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(
        0deg,
        transparent,
        transparent 2px,
        rgba(0, 0, 0, 0.03) 2px,
        rgba(0, 0, 0, 0.03) 4px
    );
    pointer-events: none;
    z-index: 9999;
}

/* Top bar */
.topbar {
    position: sticky;
    top: 0;
    z-index: 100;
    background: var(--bg-1);
    border-bottom: 1px solid var(--border);
    padding: 0 24px;
    height: 52px;
    display: flex;
    align-items: center;
    gap: 16px;
    backdrop-filter: blur(12px);
}

.topbar-logo {
    font-family: var(--mono);
    font-weight: 700;
    font-size: 17px;
    letter-spacing: -0.5px;
    color: var(--green);
    text-decoration: none;
    display: flex;
    align-items: center;
    gap: 8px;
}

.topbar-logo .logo-svg {
    filter: drop-shadow(0 0 6px rgba(0, 230, 118, 0.4));
}

.topbar-logo .logo-arc {
    transform-origin: center;
    animation: logo-spin 8s linear infinite;
}

@keyframes logo-spin {
    to { transform: rotate(360deg); }
}

@keyframes pulse-led {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

.topbar-nav {
    display: flex;
    gap: 4px;
    margin-left: auto;
}

.topbar-nav a {
    font-family: var(--mono);
    font-size: 14px;
    font-weight: 500;
    color: var(--text-2);
    text-decoration: none;
    padding: 6px 12px;
    border-radius: 4px;
    transition: all 0.15s;
}

.topbar-nav a:hover, .topbar-nav a.active {
    color: var(--text-0);
    background: var(--bg-3);
}

.health-badge {
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 500;
    padding: 3px 10px;
    border-radius: 3px;
    display: flex;
    align-items: center;
    gap: 6px;
}

.health-badge.ok {
    color: var(--green);
    background: var(--green-glow);
    border: 1px solid rgba(0, 230, 118, 0.2);
}

.health-badge.down {
    color: var(--red);
    background: var(--red-glow);
    border: 1px solid rgba(255, 23, 68, 0.2);
}

/* Main content */
.main {
    max-width: 1200px;
    margin: 0 auto;
    padding: 32px 24px;
}

.page-header {
    margin-bottom: 32px;
}

.page-title {
    font-family: var(--mono);
    font-size: 26px;
    font-weight: 700;
    letter-spacing: -0.5px;
    margin-bottom: 4px;
}

.page-subtitle {
    font-size: 15px;
    color: var(--text-2);
}

/* Service grid */
.svc-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
    gap: 16px;
}

.svc-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 20px;
    position: relative;
    transition: border-color 0.2s, box-shadow 0.2s;
    overflow: hidden;
}

.svc-card::before {
    content: '';
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 2px;
    background: var(--border);
    transition: background 0.2s;
}

.svc-card.running::before {
    background: var(--green);
    box-shadow: 0 0 12px var(--green-glow);
}

.svc-card.stopped::before {
    background: var(--red);
    box-shadow: 0 0 12px var(--red-glow);
}

.svc-card:hover {
    border-color: var(--border-hi);
    box-shadow: 0 4px 24px rgba(0, 0, 0, 0.3);
}

.svc-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    margin-bottom: 16px;
}

.svc-name {
    font-family: var(--mono);
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.3px;
}

.svc-name a {
    color: var(--text-0);
    text-decoration: none;
}

.svc-name a:hover {
    color: var(--green);
}

.status-led {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
    margin-top: 5px;
}

.status-led.on {
    background: var(--green);
    box-shadow: 0 0 6px var(--green), 0 0 12px rgba(0, 230, 118, 0.4);
}

.status-led.off {
    background: var(--red);
    box-shadow: 0 0 6px var(--red), 0 0 12px rgba(255, 23, 68, 0.3);
}

.svc-meta {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 4px 12px;
    font-size: 14px;
    margin-bottom: 16px;
}

.svc-meta dt {
    color: var(--text-2);
    font-family: var(--mono);
    font-weight: 500;
    text-transform: uppercase;
    font-size: 12px;
    letter-spacing: 0.5px;
    padding-top: 1px;
}

.svc-meta dd {
    color: var(--text-1);
    font-family: var(--mono);
    font-size: 14px;
}

.svc-actions {
    display: flex;
    gap: 8px;
    padding-top: 16px;
    border-top: 1px solid var(--border);
}

/* Buttons */
.btn {
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.3px;
    text-transform: uppercase;
    padding: 7px 14px;
    border: 1px solid var(--border);
    border-radius: 4px;
    background: var(--bg-2);
    color: var(--text-1);
    cursor: pointer;
    transition: all 0.15s;
    text-decoration: none;
    display: inline-flex;
    align-items: center;
    gap: 6px;
}

.btn:hover {
    background: var(--bg-3);
    color: var(--text-0);
    border-color: var(--border-hi);
}

.btn-deploy {
    background: rgba(0, 230, 118, 0.08);
    border-color: rgba(0, 230, 118, 0.25);
    color: var(--green);
}

.btn-deploy:hover {
    background: rgba(0, 230, 118, 0.15);
    border-color: rgba(0, 230, 118, 0.4);
    color: var(--green);
    box-shadow: 0 0 16px rgba(0, 230, 118, 0.1);
}

.btn-deploy:disabled {
    opacity: 0.5;
    cursor: not-allowed;
}

.btn-deploy.deploying {
    animation: deploy-pulse 1s ease-in-out infinite;
}

@keyframes deploy-pulse {
    0%, 100% { box-shadow: 0 0 8px rgba(0, 230, 118, 0.1); }
    50% { box-shadow: 0 0 20px rgba(0, 230, 118, 0.25); }
}

/* Deploy output */
.deploy-output {
    display: none;
    margin-top: 12px;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 12px;
    font-family: var(--mono);
    font-size: 13px;
    line-height: 1.7;
    max-height: 200px;
    overflow-y: auto;
    color: var(--text-1);
}

.deploy-output.visible { display: block; }

.deploy-output .step-ok { color: var(--green); }
.deploy-output .step-fail { color: var(--red); }
.deploy-output .step-label { color: var(--text-2); }

/* Log viewer */
.log-viewer {
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: 6px;
    overflow: hidden;
}

.log-toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    background: var(--bg-1);
    border-bottom: 1px solid var(--border);
    flex-wrap: wrap;
}

.log-type-tabs {
    display: flex;
    gap: 2px;
    background: var(--bg-0);
    border-radius: 4px;
    padding: 2px;
}

.log-type-tab {
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 500;
    padding: 4px 10px;
    border: none;
    border-radius: 3px;
    background: transparent;
    color: var(--text-2);
    cursor: pointer;
    transition: all 0.15s;
}

.log-type-tab:hover { color: var(--text-1); }
.log-type-tab.active { background: var(--bg-3); color: var(--text-0); }

.log-search {
    margin-left: auto;
    display: flex;
    gap: 4px;
}

.log-search input {
    font-family: var(--mono);
    font-size: 14px;
    padding: 5px 10px;
    background: var(--bg-0);
    border: 1px solid var(--border);
    border-radius: 3px;
    color: var(--text-0);
    width: 200px;
    outline: none;
    transition: border-color 0.15s;
}

.log-search input:focus {
    border-color: var(--green);
    box-shadow: 0 0 0 1px rgba(0, 230, 118, 0.15);
}

.log-search input::placeholder { color: var(--text-2); }

.log-content {
    padding: 12px 14px;
    font-family: var(--mono);
    font-size: 13px;
    line-height: 1.65;
    max-height: 500px;
    overflow-y: auto;
    color: var(--text-1);
    white-space: pre;
    overflow-x: auto;
}

.log-content .log-error { color: var(--red); }
.log-content .log-warn { color: var(--amber); }
.log-content .log-info { color: var(--text-2); }
.log-content .log-highlight { background: rgba(255, 171, 0, 0.15); padding: 0 2px; border-radius: 2px; }

.log-empty {
    color: var(--text-2);
    font-style: italic;
    padding: 40px 0;
    text-align: center;
}

/* Analysis panel */
.analysis-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin-top: 24px;
}

.analysis-card {
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 16px;
}

.analysis-card h3 {
    font-family: var(--mono);
    font-size: 13px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-2);
    margin-bottom: 12px;
}

.analysis-card.full-width {
    grid-column: 1 / -1;
}

.stat-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 6px 0;
    border-bottom: 1px solid var(--border);
    font-family: var(--mono);
    font-size: 14px;
}

.stat-row:last-child { border-bottom: none; }

.stat-label { color: var(--text-1); }

.stat-value {
    font-weight: 600;
    color: var(--text-0);
}

.stat-value.error { color: var(--red); }
.stat-value.warn { color: var(--amber); }
.stat-value.ok { color: var(--green); }

.status-code-grid {
    display: flex;
    gap: 8px;
    flex-wrap: wrap;
}

.status-code-chip {
    font-family: var(--mono);
    font-size: 14px;
    font-weight: 600;
    padding: 4px 10px;
    border-radius: 3px;
    display: flex;
    gap: 6px;
    align-items: center;
}

.status-code-chip.s2xx { background: var(--green-glow); color: var(--green); }
.status-code-chip.s3xx { background: var(--blue-glow); color: var(--blue); }
.status-code-chip.s4xx { background: var(--amber-glow); color: var(--amber); }
.status-code-chip.s5xx { background: var(--red-glow); color: var(--red); }

.status-code-chip .count {
    font-weight: 400;
    opacity: 0.7;
}

/* Detail page layout */
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
    background: var(--bg-1);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 20px;
}

.detail-info h2 {
    font-family: var(--mono);
    font-size: 20px;
    font-weight: 700;
    margin-bottom: 16px;
    display: flex;
    align-items: center;
    gap: 10px;
}

.detail-meta {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 8px 14px;
    font-size: 14px;
    margin-bottom: 20px;
}

.detail-meta dt {
    color: var(--text-2);
    font-family: var(--mono);
    font-weight: 600;
    text-transform: uppercase;
    font-size: 12px;
    letter-spacing: 0.5px;
    padding-top: 2px;
}

.detail-meta dd {
    color: var(--text-1);
    font-family: var(--mono);
    font-size: 14px;
    word-break: break-all;
}

.section-title {
    font-family: var(--mono);
    font-size: 15px;
    font-weight: 600;
    letter-spacing: -0.3px;
    margin-bottom: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
}

/* Spinner */
.spinner {
    width: 14px;
    height: 14px;
    border: 2px solid var(--border);
    border-top-color: var(--green);
    border-radius: 50%;
    animation: spin 0.6s linear infinite;
    display: inline-block;
}

@keyframes spin {
    to { transform: rotate(360deg); }
}

/* Loading skeleton */
.skeleton {
    background: linear-gradient(90deg, var(--bg-2) 25%, var(--bg-3) 50%, var(--bg-2) 75%);
    background-size: 200% 100%;
    animation: shimmer 1.5s infinite;
    border-radius: 4px;
    height: 16px;
}

@keyframes shimmer {
    0% { background-position: 200% 0; }
    100% { background-position: -200% 0; }
}

/* Responsive */
@media (max-width: 768px) {
    .detail-grid { grid-template-columns: 1fr; }
    .detail-sidebar { position: static; }
    .analysis-grid { grid-template-columns: 1fr; }
    .svc-grid { grid-template-columns: 1fr; }
}

/* Toast notifications */
.toast-container {
    position: fixed;
    bottom: 24px;
    right: 24px;
    z-index: 1000;
    display: flex;
    flex-direction: column;
    gap: 8px;
}

.toast {
    font-family: var(--mono);
    font-size: 14px;
    padding: 10px 16px;
    border-radius: 4px;
    border: 1px solid var(--border);
    background: var(--bg-2);
    color: var(--text-0);
    box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    animation: toast-in 0.3s ease-out;
    max-width: 360px;
}

.toast.success { border-left: 3px solid var(--green); }
.toast.error { border-left: 3px solid var(--red); }

@keyframes toast-in {
    from { opacity: 0; transform: translateY(12px); }
    to { opacity: 1; transform: translateY(0); }
}
</style>
</head>
<body>

<div class="topbar">
    <a href="/" class="topbar-logo">
        <svg class="logo-svg" width="36" height="36" viewBox="0 0 36 36" fill="none" xmlns="http://www.w3.org/2000/svg">
            <circle cx="18" cy="18" r="17" stroke="currentColor" stroke-width="1.5" opacity="0.3"/>
            <circle cx="18" cy="18" r="17" stroke="currentColor" stroke-width="1.5" stroke-dasharray="106.8" stroke-dashoffset="26.7" class="logo-arc" />
            <text x="18" y="22" text-anchor="middle" fill="currentColor" font-family="'JetBrains Mono', monospace" font-weight="700" font-size="13">321</text>
        </svg>
        <span>.do</span>
    </a>
    <div id="health-badge" class="health-badge ok">
        <span id="health-status">...</span>
    </div>
    <nav class="topbar-nav">
        <a href="/">dashboard</a>
    </nav>
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

async function loadHealth() {
    try {
        const d = await api('/health');
        const b = document.getElementById('health-badge');
        const s = document.getElementById('health-status');
        if (d.status === 'success') {
            const running = d.data.services.running;
            const total = d.data.services.total;
            s.textContent = running + '/' + total + ' up';
            b.className = 'health-badge ' + (running === total ? 'ok' : 'down');
        }
    } catch(e) {}
}

loadHealth();
setInterval(loadHealth, 15000);
</script>

<%= content_for 'scripts' %>

</body>
</html>

@@ dashboard.html.ep
% layout 'ops';
% title 'Dashboard';

<div class="page-header">
    <div class="page-title">Services</div>
    <div class="page-subtitle">Manage deployments and monitor logs</div>
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
    d.data.forEach(svc => {
        const running = svc.running;
        const card = document.createElement('div');
        card.className = 'svc-card ' + (running ? 'running' : 'stopped');
        card.innerHTML = `
            <div class="svc-header">
                <div class="svc-name"><a href="/ui/service/${svc.name}">${svc.name}</a></div>
                <div class="status-led ${running ? 'on' : 'off'}"></div>
            </div>
            <dl class="svc-meta">
                <dt>Port</dt><dd>${svc.port || '—'}</dd>
                <dt>PID</dt><dd>${svc.pid || '—'}</dd>
                <dt>SHA</dt><dd>${svc.git_sha || '—'}</dd>
                <dt>Branch</dt><dd>${svc.branch || '—'}</dd>
            </dl>
            <div class="svc-actions">
                <button class="btn btn-deploy" onclick="deployService('${svc.name}', this)" id="deploy-btn-${svc.name.replace(/\./g,'_')}">
                    ▸ Deploy
                </button>
                <a href="/ui/service/${svc.name}" class="btn">Details</a>
                <a href="/ui/service/${svc.name}#logs" class="btn">Logs</a>
            </div>
            <div class="deploy-output" id="deploy-out-${svc.name.replace(/\./g,'_')}"></div>
        `;
        grid.appendChild(card);
    });
}

async function deployService(name, btn) {
    const safeId = name.replace(/\./g, '_');
    const out = document.getElementById('deploy-out-' + safeId);
    btn.disabled = true;
    btn.classList.add('deploying');
    btn.innerHTML = '<span class="spinner"></span> Deploying';
    out.classList.add('visible');
    out.innerHTML = '<span class="step-label">Starting deploy...</span>\n';

    try {
        const d = await api('/service/' + name + '/deploy', { method: 'POST' });
        out.innerHTML = '';
        if (d.data && d.data.steps) {
            d.data.steps.forEach(step => {
                const ok = (typeof step.success === 'boolean') ? step.success : step.success;
                const cls = ok ? 'step-ok' : 'step-fail';
                const icon = ok ? '✓' : '✗';
                out.innerHTML += `<span class="${cls}">${icon}</span> <span class="step-label">${step.step}</span>  ${(step.output||'').substring(0, 120)}\n`;
            });
        }
        if (d.status === 'success') {
            toast(name + ' deployed successfully');
        } else {
            toast(d.message || 'Deploy failed', 'error');
        }
    } catch(e) {
        out.innerHTML += '<span class="step-fail">✗ Network error: ' + e.message + '</span>\n';
        toast('Deploy failed: ' + e.message, 'error');
    }

    btn.disabled = false;
    btn.classList.remove('deploying');
    btn.innerHTML = '▸ Deploy';
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
    <div class="page-title"><a href="/" style="color:var(--text-2);text-decoration:none">←</a> &nbsp;<%= $service_name %></div>
</div>

<div class="detail-grid">
    <div class="detail-sidebar">
        <div class="detail-info">
            <h2>
                <span class="status-led" id="svc-led"></span>
                <span id="svc-title"><%= $service_name %></span>
            </h2>
            <dl class="detail-meta" id="svc-meta">
                <dt>Status</dt><dd id="m-status">loading...</dd>
                <dt>Port</dt><dd id="m-port">—</dd>
                <dt>PID</dt><dd id="m-pid">—</dd>
                <dt>SHA</dt><dd id="m-sha">—</dd>
                <dt>Branch</dt><dd id="m-branch">—</dd>
                <dt>Repo</dt><dd id="m-repo">—</dd>
            </dl>
            <button class="btn btn-deploy" id="deploy-btn" onclick="deploy()" style="width:100%;justify-content:center">
                ▸ Deploy
            </button>
            <div class="deploy-output" id="deploy-out"></div>
        </div>
    </div>

    <div class="detail-main">
        <div class="section-title">Log Viewer</div>
        <div class="log-viewer">
            <div class="log-toolbar">
                <div class="log-type-tabs" id="log-tabs"></div>
                <div class="log-search">
                    <input type="text" id="log-search-input" placeholder="Search logs..." onkeydown="if(event.key==='Enter')searchLogs()">
                    <button class="btn" onclick="searchLogs()">Search</button>
                </div>
            </div>
            <div class="log-content" id="log-content"><span class="log-empty">Select a log type to view</span></div>
        </div>

        <div class="section-title" style="margin-top:24px">Analysis</div>
        <div id="analysis-container">
            <div class="analysis-card"><div class="skeleton" style="width:50%;margin-bottom:8px"></div><div class="skeleton" style="width:70%"></div></div>
        </div>
    </div>
</div>

% content_for scripts => begin
<script>
const SVC = '<%= $service_name %>';
let currentLogType = null;
let svcConfig = null;

async function loadStatus() {
    const d = await api('/service/' + SVC + '/status');
    if (d.status !== 'success') return;
    const s = d.data;
    document.getElementById('svc-led').className = 'status-led ' + (s.running ? 'on' : 'off');
    document.getElementById('m-status').textContent = s.running ? 'Running' : 'Stopped';
    document.getElementById('m-status').style.color = s.running ? 'var(--green)' : 'var(--red)';
    document.getElementById('m-port').textContent = s.port || '—';
    document.getElementById('m-pid').textContent = s.pid || '—';
    document.getElementById('m-sha').textContent = s.git_sha || '—';
    document.getElementById('m-branch').textContent = s.branch || '—';
    document.getElementById('m-repo').textContent = s.repo || '—';
}

async function initLogTabs() {
    // Get service config to find available log types
    const d = await api('/services');
    if (d.status !== 'success') return;
    const svc = d.data.find(s => s.name === SVC);
    if (!svc) return;

    // Fetch service config for log types — we'll try common types
    const tabs = document.getElementById('log-tabs');
    const logTypes = ['stdout', 'stderr', 'app', 'ubic'];
    tabs.innerHTML = '';
    logTypes.forEach(type => {
        const btn = document.createElement('button');
        btn.className = 'log-type-tab';
        btn.textContent = type;
        btn.onclick = () => selectLogType(type, btn);
        tabs.appendChild(btn);
    });
    // Auto-select stderr
    const stderrTab = tabs.querySelector('.log-type-tab:nth-child(2)');
    if (stderrTab) selectLogType('stderr', stderrTab);
}

async function selectLogType(type, btn) {
    currentLogType = type;
    document.querySelectorAll('.log-type-tab').forEach(t => t.classList.remove('active'));
    btn.classList.add('active');
    await loadLogs(type);
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
    if (s.includes('<span')) return s; // already formatted
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

    // Status codes
    html += '<div class="analysis-grid">';
    html += '<div class="analysis-card"><h3>HTTP Status Codes</h3>';
    if (Object.keys(a.statusCodes || {}).length > 0) {
        html += '<div class="status-code-grid">';
        Object.entries(a.statusCodes).sort().forEach(([code, count]) => {
            const cls = code < 300 ? 's2xx' : code < 400 ? 's3xx' : code < 500 ? 's4xx' : 's5xx';
            html += `<div class="status-code-chip ${cls}">${code} <span class="count">×${count}</span></div>`;
        });
        html += '</div>';
    } else {
        html += '<span class="log-empty">No status codes found</span>';
    }
    html += '</div>';

    // Errors
    html += '<div class="analysis-card"><h3>Errors</h3>';
    if (a.errors && a.errors.length > 0) {
        a.errors.slice(0, 8).forEach(e => {
            html += `<div class="stat-row"><span class="stat-label">${escHtml(e.pattern.substring(0,60))}</span><span class="stat-value error">×${e.count}</span></div>`;
        });
    } else {
        html += '<span class="stat-value ok" style="font-size:14px">No errors</span>';
    }
    html += '</div>';

    // Warnings
    html += '<div class="analysis-card"><h3>Warnings</h3>';
    if (a.warnings && a.warnings.length > 0) {
        a.warnings.slice(0, 8).forEach(w => {
            html += `<div class="stat-row"><span class="stat-label">${escHtml(w.pattern.substring(0,60))}</span><span class="stat-value warn">×${w.count}</span></div>`;
        });
    } else {
        html += '<span class="stat-value ok" style="font-size:14px">No warnings</span>';
    }
    html += '</div>';

    // Summary
    html += `<div class="analysis-card"><h3>Summary</h3>
        <div class="stat-row"><span class="stat-label">Period</span><span class="stat-value">${a.period}</span></div>
        <div class="stat-row"><span class="stat-label">Requests tracked</span><span class="stat-value">${a.requestCount || 0}</span></div>
        <div class="stat-row"><span class="stat-label">Error patterns</span><span class="stat-value ${a.errors.length ? 'error' : 'ok'}">${a.errors.length}</span></div>
        <div class="stat-row"><span class="stat-label">Warning patterns</span><span class="stat-value ${a.warnings.length ? 'warn' : 'ok'}">${a.warnings.length}</span></div>
    </div>`;

    html += '</div>';
    container.innerHTML = html;
}

async function deploy() {
    const btn = document.getElementById('deploy-btn');
    const out = document.getElementById('deploy-out');
    btn.disabled = true;
    btn.classList.add('deploying');
    btn.innerHTML = '<span class="spinner"></span> Deploying...';
    out.classList.add('visible');
    out.innerHTML = '<span class="step-label">Starting deploy...</span>\n';

    try {
        const d = await api('/service/' + SVC + '/deploy', { method: 'POST' });
        out.innerHTML = '';
        if (d.data && d.data.steps) {
            d.data.steps.forEach(step => {
                const ok = (typeof step.success === 'boolean') ? step.success : step.success;
                const cls = ok ? 'step-ok' : 'step-fail';
                const icon = ok ? '✓' : '✗';
                out.innerHTML += `<span class="${cls}">${icon}</span> <span class="step-label">${step.step}</span>  ${(step.output||'').substring(0, 200)}\n`;
            });
        }
        if (d.status === 'success') {
            toast(SVC + ' deployed successfully');
        } else {
            toast(d.message || 'Deploy failed', 'error');
        }
    } catch(e) {
        out.innerHTML += '<span class="step-fail">✗ ' + e.message + '</span>\n';
        toast('Deploy error: ' + e.message, 'error');
    }

    btn.disabled = false;
    btn.classList.remove('deploying');
    btn.innerHTML = '▸ Deploy';
    loadStatus();
}

loadStatus();
initLogTabs();
loadAnalysis();
setInterval(loadStatus, 10000);
</script>
% end
