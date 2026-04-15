package Deploy::Nginx;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);

has 'config';  # Deploy::Config instance
has 'log';     # Mojo::Log instance (optional)

has 'sites_available' => '/etc/nginx/sites-available';
has 'sites_enabled'   => '/etc/nginx/sites-enabled';

sub _valid_host ($self, $host) {
    return $host && $host =~ /^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?$/;
}

sub generate ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    my $port = $svc->{port};
    return { status => 'error', message => "No port configured for $name" } unless $port;
    return { status => 'error', message => "Invalid hostname: $host" } unless $self->_valid_host($host);

    my $has_ssl = -f "/etc/letsencrypt/live/$host/fullchain.pem";
    my $conf = $self->_render_config($host, $port, $has_ssl);
    my $file = path($self->sites_available, $host);

    $file->spew_utf8($conf);
    $self->log->info("Generated nginx config: $file") if $self->log;

    return { status => 'ok', file => "$file", host => $host, port => $port, ssl => $has_ssl };
}

sub enable ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    my $source = path($self->sites_available, $host);
    my $link   = path($self->sites_enabled, $host);

    return { status => 'error', message => "Config not found: $source" } unless $source->exists;

    unlink $link if -l $link;
    symlink($source->absolute, $link)
        or return { status => 'error', message => "Symlink failed: $!" };

    $self->log->info("Enabled nginx site: $host") if $self->log;
    return { status => 'ok', link => "$link" };
}

sub test ($self) {
    my $output = `nginx -t 2>&1`;
    my $ok = $? == 0;
    return { status => ($ok ? 'ok' : 'error'), output => $output };
}

sub reload ($self) {
    my $test = $self->test;
    return $test unless $test->{status} eq 'ok';

    my $output = `systemctl reload nginx 2>&1`;
    my $ok = $? == 0;
    $self->log->info("Nginx reloaded") if $self->log && $ok;
    return { status => ($ok ? 'ok' : 'error'), output => $output };
}

sub certbot ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    return { status => 'error', message => "Invalid hostname: $host" } unless $self->_valid_host($host);
    return { status => 'ok', message => 'SSL cert already exists' }
        if -f "/etc/letsencrypt/live/$host/fullchain.pem";

    my @cmd = ('certbot', 'certonly', '--standalone', '-d', $host,
               '--non-interactive', '--agree-tos', '-m', "admin\@$host");
    my $output = `@cmd 2>&1`;
    my $ok = $? == 0;
    return { status => ($ok ? 'ok' : 'error'), output => $output };
}

sub setup ($self, $name) {
    my @steps;

    my $gen = $self->generate($name);
    push @steps, { step => 'generate_config', success => $gen->{status} eq 'ok' ? \1 : \0, output => $gen->{file} // $gen->{message} };
    return { status => 'error', message => $gen->{message}, steps => \@steps } unless $gen->{status} eq 'ok';

    my $en = $self->enable($name);
    push @steps, { step => 'enable_site', success => $en->{status} eq 'ok' ? \1 : \0, output => $en->{link} // $en->{message} };

    my $test = $self->test;
    push @steps, { step => 'test_config', success => $test->{status} eq 'ok' ? \1 : \0, output => $test->{output} };
    return { status => 'error', message => 'Nginx config test failed', steps => \@steps } unless $test->{status} eq 'ok';

    my $reload = $self->reload;
    push @steps, { step => 'reload_nginx', success => $reload->{status} eq 'ok' ? \1 : \0, output => $reload->{output} };

    my $ok = $reload->{status} eq 'ok';
    return { status => ($ok ? 'ok' : 'error'), message => ($ok ? "Nginx configured for $name" : 'Nginx reload failed'), steps => \@steps };
}

sub status ($self, $name) {
    my $svc = $self->config->service($name);
    return undef unless $svc;

    my $host = $svc->{host} // 'localhost';
    return {
        config_exists  => -f path($self->sites_available, $host),
        enabled        => -l path($self->sites_enabled, $host),
        ssl            => -f "/etc/letsencrypt/live/$host/fullchain.pem" ? 1 : 0,
        host           => $host,
    };
}

sub _render_config ($self, $host, $port, $has_ssl) {
    my $conf = <<"NGINX";
server {
    listen 80;
    listen [::]:80;
    server_name $host;

NGINX

    if ($has_ssl) {
        $conf .= "    return 301 https://\$host\$request_uri;\n}\n\n";
        $conf .= <<"NGINX";
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $host;

    ssl_certificate     /etc/letsencrypt/live/$host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;

    ssl_protocols TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

NGINX
    }

    $conf .= <<"NGINX";
    access_log /var/log/nginx/${host}.access.log;
    error_log  /var/log/nginx/${host}.error.log;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
    }
}
NGINX

    return $conf;
}

1;
