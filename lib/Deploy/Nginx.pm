package Deploy::Nginx;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);
use Time::Piece;
use Deploy::CertProvider;

# Days from now until an openssl notAfter date ("Oct 18 17:33:59 2026 GMT").
# undef if the string can't be parsed. Pure - unit tested.
sub _days_until ($enddate) {
    return undef unless defined $enddate;
    (my $s = $enddate) =~ s/\s*GMT\s*$//i;
    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    my $t = eval { Time::Piece->strptime($s, '%b %d %H:%M:%S %Y') };
    return undef if $@ || !$t;
    return int(($t->epoch - time) / 86400);
}

# Classify a served cert from host + its CN/SANs + days-until-expiry. The
# renewal window is 30 days (the certbot convention). `ok` means the cert is
# currently serviceable (matches the host and not expired); `expiring` is the
# separate "renew soon" signal. Pure - unit tested.
sub _cert_verdict ($host, $cn, $sans, $days) {
    my @candidates = grep { defined && length } ($cn, @$sans);
    my $host_match = (grep { lc($_) eq lc($host) } @candidates) ? 1 : 0;
    my $expired  = (defined $days && $days <= 0)              ? 1 : 0;
    my $expiring = (defined $days && $days > 0 && $days < 30) ? 1 : 0;

    my $error;
    if    (!$host_match) { $error = "cert is for " . ($cn // 'unknown') . ", not $host" }
    elsif ($expired)     { $error = "certificate expired " . abs($days) . " day(s) ago" }
    elsif ($expiring)    { $error = "certificate expires in $days days" }

    return {
        ok             => ($host_match && !$expired) ? 1 : 0,
        host_match     => $host_match,
        expired        => $expired,
        expiring       => $expiring,
        days_remaining => $days,
        ($error ? (error => $error) : ()),
    };
}

has 'config';     # Deploy::Config instance
has 'log';        # Mojo::Log instance (optional)
has 'transport';  # Deploy::SSH or Deploy::Local instance (optional)

has 'sites_available' => '/etc/nginx/sites-available';
has 'sites_enabled'   => '/etc/nginx/sites-enabled';

has 'cert_provider' => sub { Deploy::CertProvider->new };

sub _valid_host ($self, $host) {
    return $host && $host =~ /^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?$/;
}

sub _file_exists ($self, $path, %opt) {
    my $sudo = $opt{sudo};
    if ($self->transport) {
        my $cmd = ($sudo ? 'sudo ' : '') . "test -f $path";
        return $self->transport->run($cmd)->{ok} ? 1 : 0;
    }
    return -f $path ? 1 : 0;
}

sub _run ($self, $cmd) {
    if ($self->transport) {
        my $r = $self->transport->run("$cmd 2>&1");
        return { ok => $r->{ok}, output => $r->{output} };
    }
    my $output = `$cmd 2>&1`;
    return { ok => ($? == 0), output => $output };
}

sub generate ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    my $port = $svc->{port};
    return { status => 'error', message => "No port configured for $name" } unless $port;
    return { status => 'error', message => "Invalid hostname: $host" } unless $self->_valid_host($host);

    my @aliases = @{ $svc->{aliases} // [] };
    for my $alias (@aliases) {
        return { status => 'error', message => "Invalid alias: $alias" } unless $self->_valid_host($alias);
    }

    my $provider = $self->cert_provider->pick($self->config->target);
    my $paths    = $self->cert_provider->cert_paths(provider => $provider, host => $host);
    # /etc/letsencrypt/live/ is root-readable; sudo so unprivileged probes work.
    my $has_ssl = $self->_file_exists($paths->{cert}, sudo => 1);

    # force_https defaults true: HTTP redirects to HTTPS when SSL is set up.
    # Set force_https: false in 321.yml for APIs that should answer on HTTP too.
    my $force_https = $svc->{force_https} // 1;
    my $conf = $self->_render_config($host, $port, $has_ssl, $paths, $force_https, \@aliases);

    my $dest = $self->sites_available . "/$host";

    if ($self->transport && $self->transport->isa('Deploy::SSH')) {
        require File::Temp;
        my $tmp = File::Temp->new(SUFFIX => '.conf');
        print $tmp $conf;
        close $tmp;
        $self->transport->upload($tmp->filename, "/tmp/$host.conf");
        $self->transport->run("sudo mv /tmp/$host.conf $dest");
    } elsif ($dest =~ m{^/etc/}) {
        # System path - needs sudo
        require File::Temp;
        my $tmp = File::Temp->new(SUFFIX => '.conf');
        print $tmp $conf;
        close $tmp;
        system("sudo mv ${\$tmp->filename} $dest") == 0
            or return { status => 'error', message => "Failed to write nginx config (sudo needed)" };
    } else {
        # Non-system path (tests) - write directly
        path($dest)->spew_utf8($conf);
    }

    my $file = path($self->sites_available, $host);
    $self->log->info("Generated nginx config: $file") if $self->log;

    return { status => 'ok', file => "$file", host => $host, port => $port, ssl => $has_ssl };
}

sub enable ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    my $source = path($self->sites_available, $host);
    my $link   = path($self->sites_enabled, $host);

    if ($self->transport && $self->transport->isa('Deploy::SSH')) {
        my $r = $self->transport->run(
            "sudo ln -sf /etc/nginx/sites-available/$host /etc/nginx/sites-enabled/$host"
        );
        return { status => 'error', message => "Symlink failed: $r->{output}" } unless $r->{ok};
    } elsif ("$link" =~ m{^/etc/}) {
        return { status => 'error', message => "Config not found: $source" } unless $source->exists;
        system("sudo ln -sf $source $link") == 0
            or return { status => 'error', message => "Symlink failed (sudo needed)" };
    } else {
        return { status => 'error', message => "Config not found: $source" } unless $source->exists;
        unlink $link if -l $link;
        symlink($source->absolute, $link)
            or return { status => 'error', message => "Symlink failed: $!" };
    }

    $self->log->info("Enabled nginx site: $host") if $self->log;
    return { status => 'ok', link => "$link" };
}

sub test ($self) {
    if ($self->transport) {
        my $r = $self->transport->run('sudo nginx -t');
        return { ok => $r->{ok}, output => $r->{output} };
    }
    my $output = `sudo nginx -t 2>&1`;
    return { ok => ($? == 0), output => $output };
}

sub reload ($self) {
    my $test = $self->test;
    return { status => 'error', message => "nginx -t failed: $test->{output}" } unless $test->{ok};

    if ($self->transport) {
        my $r = $self->transport->run('sudo systemctl reload nginx');
        return { status => $r->{ok} ? 'ok' : 'error', output => $r->{output} };
    }
    my $output = `sudo systemctl reload nginx 2>&1`;
    my $ok = $? == 0;
    $self->log->info("Nginx reloaded") if $self->log && $ok;
    return { status => ($ok ? 'ok' : 'error'), output => $output };
}

sub acquire_cert ($self, $name) {
    my $svc = $self->config->service($name);
    return { status => 'error', message => "Unknown service: $name" } unless $svc;

    my $host = $svc->{host} // 'localhost';
    return { status => 'error', message => "Invalid hostname: $host" } unless $self->_valid_host($host);

    my @aliases = grep { $self->_valid_host($_) } @{ $svc->{aliases} // [] };

    my $provider = $self->cert_provider->pick($self->config->target);
    my $paths    = $self->cert_provider->cert_paths(provider => $provider, host => $host);

    if ($self->_file_exists($paths->{cert}, sudo => 1)) {
        return { status => 'ok', message => 'SSL cert already exists' } unless @aliases;

        # Cert exists but may predate the aliases - re-acquire only if a
        # configured alias is missing from its SAN list.
        my $sans = $self->_run("sudo openssl x509 -in $paths->{cert} -noout -ext subjectAltName")->{output} // '';
        my @missing = grep { $sans !~ /DNS:\Q$_\E(?![\w.-])/i } @aliases;
        return { status => 'ok', message => 'SSL cert already covers aliases' } unless @missing;
    }

    my $cmd = $self->cert_provider->acquire_cmd(provider => $provider, host => $host, aliases => \@aliases);
    my $r   = $self->_run($cmd);
    return { status => ($r->{ok} ? 'ok' : 'error'), output => $r->{output}, provider => $provider };
}

sub certbot ($self, $name) { $self->acquire_cert($name) }  # backwards compat

sub setup ($self, $name) {
    my @steps;

    my $gen = $self->generate($name);
    push @steps, { step => 'generate_config', success => $gen->{status} eq 'ok' ? \1 : \0, output => $gen->{file} // $gen->{message} };
    return { status => 'error', message => $gen->{message}, steps => \@steps } unless $gen->{status} eq 'ok';

    my $en = $self->enable($name);
    push @steps, { step => 'enable_site', success => $en->{status} eq 'ok' ? \1 : \0, output => $en->{link} // $en->{message} };

    my $test = $self->test;
    push @steps, { step => 'test_config', success => $test->{ok} ? \1 : \0, output => $test->{output} };
    return { status => 'error', message => 'Nginx config test failed', steps => \@steps } unless $test->{ok};

    my $reload = $self->reload;
    push @steps, { step => 'reload_nginx', success => $reload->{status} eq 'ok' ? \1 : \0, output => $reload->{output} };

    my $ok = $reload->{status} eq 'ok';
    return { status => ($ok ? 'ok' : 'error'), message => ($ok ? "Nginx configured for $name" : 'Nginx reload failed'), steps => \@steps };
}

sub status ($self, $name) {
    my $svc = $self->config->service($name);
    return undef unless $svc;

    my $host     = $svc->{host} // 'localhost';
    my $provider = $self->cert_provider->pick($self->config->target);
    my $paths    = $self->cert_provider->cert_paths(provider => $provider, host => $host);

    my $avail = path($self->sites_available, $host);
    my $link  = path($self->sites_enabled,   $host);

    my ($config_exists, $enabled, $ssl);
    if ($self->transport) {
        # One round trip - letsencrypt path needs sudo; the others don't.
        my $out = $self->transport->run(
            "test -f $avail && echo A; "
          . "test -L $link  && echo B; "
          . "sudo test -f $paths->{cert} && echo C"
        )->{output} // '';
        $config_exists = $out =~ /^A$/m ? 1 : 0;
        $enabled       = $out =~ /^B$/m ? 1 : 0;
        $ssl           = $out =~ /^C$/m ? 1 : 0;
    } else {
        $config_exists = -f $avail        ? 1 : 0;
        $enabled       = -l $link         ? 1 : 0;
        $ssl           = -f $paths->{cert} ? 1 : 0;
    }

    return {
        config_exists => $config_exists,
        enabled       => $enabled,
        ssl           => $ssl,
        provider      => $provider,
        host          => $host,
    };
}

sub probe_cert ($self, $host) {
    return { ok => 0, host => $host, error => 'invalid host', reachable => 0 }
        unless $self->_valid_host($host);

    # Read the served cert WITHOUT chain verification, so an expired or wrong
    # cert is still inspectable (that is the whole point - we compute validity
    # ourselves from notAfter). Subject, SANs and the expiry date in one pass.
    my $connect = "timeout 5 openssl s_client -servername $host -connect $host:443 </dev/null 2>/dev/null";
    my $x509    = "openssl x509 -noout -subject -ext subjectAltName -enddate 2>/dev/null";
    my $out = `$connect | $x509`;

    unless ($out =~ /\S/) {
        # No cert came back - distinguish a dead socket from a TLS failure so
        # doctor points at the right layer.
        my $diag = `timeout 5 openssl s_client -servername $host -connect $host:443 </dev/null 2>&1`;
        my $error = $diag =~ /connect:|Connection refused|No route to host|timed out|unable to connect/i
            ? 'no TCP/TLS response (host unreachable on 443)'
            : 'TLS handshake failed (no certificate served)';
        return { ok => 0, host => $host, reachable => 0, error => $error };
    }

    my ($cn) = $out =~ /subject=.*?CN\s*=\s*([^\s,]+)/;
    my @sans;
    if ($out =~ /Subject Alternative Name:\s*\n?\s*(.+)/) {
        @sans = map { (my $s = $_) =~ s/^DNS://; $s =~ s/^\s+|\s+$//g; $s }
                split /,/, $1;
    }
    my ($enddate) = $out =~ /notAfter=(.+)/;
    $enddate =~ s/\s+$// if defined $enddate;
    my $days = _days_until($enddate);

    my $verdict = _cert_verdict($host, $cn, \@sans, $days);
    return {
        %$verdict,
        host      => $host,
        cn        => $cn,
        sans      => \@sans,
        reachable => 1,
        not_after => $enddate,
    };
}

sub _render_config ($self, $host, $port, $has_ssl, $paths, $force_https = 1, $aliases = []) {
    my $names = join ' ', $host, @$aliases;
    my $proxy_block = <<"NGINX";
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

    # ACME http-01 challenge served from webroot. Lets certbot renew without
    # any service interruption: no --standalone (which needs port 80 free).
    my $acme_block = <<"NGINX";
    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }
NGINX

    my $conf = <<"NGINX";
server {
    listen 80;
    listen [::]:80;
    server_name $names;

$acme_block
NGINX

    if ($has_ssl && $force_https) {
        # Literal canonical host, not \$host: aliases (e.g. www) go straight
        # to the canonical HTTPS site in one hop.
        $conf .= "    location / { return 301 https://$host\$request_uri; }\n}\n\n";
    } else {
        # Either no cert, or force_https is off - proxy_pass through HTTP.
        $conf .= $proxy_block;
        $conf .= "\n" if $has_ssl;
    }

    if ($has_ssl && @$aliases) {
        # Aliases answer HTTPS on the shared cert, then redirect to the
        # canonical host so there's one public URL per page.
        my $alias_names = join ' ', @$aliases;
        $conf .= <<"NGINX";
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $alias_names;

    ssl_certificate     $paths->{cert};
    ssl_certificate_key $paths->{key};

    ssl_protocols TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    return 301 https://$host\$request_uri;
}

NGINX
    }

    if ($has_ssl) {
        # HSTS only when we're forcing HTTPS - a force_https=false service
        # legitimately answers on HTTP, so don't lock browsers out.
        my $hsts = $force_https
            ? "    add_header Strict-Transport-Security \"max-age=31536000\" always;\n"
            : '';
        $conf .= <<"NGINX";
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $host;

    ssl_certificate     $paths->{cert};
    ssl_certificate_key $paths->{key};

    ssl_protocols TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

$hsts
NGINX
        $conf .= $proxy_block;
    }

    return $conf;
}

1;
