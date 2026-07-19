package Deploy::CertProvider;

# Caller must validate $host - this module performs no shell escaping.
# Hostnames reaching acquire_cmd should already be through Deploy::Nginx::_valid_host.

use Mojo::Base -base, -signatures;

# Where nginx-readable certs land (dev via mkcert). Live uses /etc/letsencrypt.
has 'ssl_dir' => '/etc/ssl/321';

# mkcert CAROOT - where mkcert stores its local CA. Preserved across `sudo`.
has 'mkcert_dir' => sub { "$ENV{HOME}/.local/share/mkcert" };

sub pick ($self, $target) {
    return $target eq 'dev' ? 'mkcert' : 'certbot';
}

sub cert_paths ($self, %o) {
    my ($provider, $host) = @o{qw(provider host)};

    if ($provider eq 'mkcert') {
        my $dir = $self->ssl_dir;
        return { cert => "$dir/$host.pem", key => "$dir/$host-key.pem" };
    }

    return {
        cert => "/etc/letsencrypt/live/$host/fullchain.pem",
        key  => "/etc/letsencrypt/live/$host/privkey.pem",
    };
}

sub acquire_cmd ($self, %o) {
    my ($provider, $host) = @o{qw(provider host)};
    my @aliases = @{ $o{aliases} // [] };
    my $paths   = $self->cert_paths(%o);

    if ($provider eq 'mkcert') {
        my $caroot = $self->mkcert_dir;
        my $dir    = $self->ssl_dir;
        my $names  = join ' ', $host, @aliases;
        return "sudo install -d -m 755 $dir && "
             . "sudo CAROOT=$caroot mkcert "
             . "-cert-file $paths->{cert} "
             . "-key-file $paths->{key} "
             . "$names && "
             . "sudo chgrp www-data $paths->{key} && "
             . "sudo chmod 640 $paths->{key}";
    }

    # --webroot lets certbot renew without stopping nginx. The acme-challenge
    # location in our nginx template serves /var/www/letsencrypt/.well-known.
    # With aliases, --cert-name pins the lineage to the canonical host (so
    # cert_paths stay stable) and --expand grows an existing cert's SAN list.
    my $domains = join ' ', map { "-d $_" } $host, @aliases;
    my $expand  = @aliases ? "--cert-name $host --expand " : '';
    return "sudo mkdir -p /var/www/letsencrypt && "
         . "sudo certbot certonly --webroot -w /var/www/letsencrypt $domains "
         . $expand
         . "--non-interactive --agree-tos -m admin\@$host";
}

1;
