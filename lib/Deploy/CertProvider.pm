package Deploy::CertProvider;

use Mojo::Base -base, -signatures;

has 'mkcert_dir' => sub { "$ENV{HOME}/.local/share/mkcert" };

sub pick ($self, $target) {
    return $target eq 'dev' ? 'mkcert' : 'certbot';
}

sub cert_paths ($self, %o) {
    my ($provider, $host) = @o{qw(provider host)};

    if ($provider eq 'mkcert') {
        my $dir = $self->mkcert_dir;
        return { cert => "$dir/$host.pem", key => "$dir/$host-key.pem" };
    }

    return {
        cert => "/etc/letsencrypt/live/$host/fullchain.pem",
        key  => "/etc/letsencrypt/live/$host/privkey.pem",
    };
}

sub acquire_cmd ($self, %o) {
    my ($provider, $host) = @o{qw(provider host)};
    my $paths = $self->cert_paths(%o);

    if ($provider eq 'mkcert') {
        my $dir = $self->mkcert_dir;
        return "mkdir -p $dir && mkcert "
             . "-cert-file $paths->{cert} "
             . "-key-file  $paths->{key} "
             . "$host";
    }

    return "certbot certonly --standalone -d $host "
         . "--non-interactive --agree-tos -m admin\@$host";
}

1;
