package Deploy::Config;

use Mojo::Base -base, -signatures;
use YAML::XS qw(LoadFile DumpFile);
use Path::Tiny qw(path);
use Mojo::File qw(curfile);

has 'app_home'    => sub { curfile->dirname->dirname->dirname };
has 'target'      => 'live';
has '_services'   => sub ($self) { $self->_load_all };

sub reload ($self) {
    $self->_services($self->_load_all);
    return $self;
}

sub _services_dir ($self) {
    return path($self->app_home, 'services');
}

my $_sops_cache;
sub _sops_path ($self) {
    return $_sops_cache if defined $_sops_cache;
    for my $p ("$ENV{HOME}/bin/sops", '/usr/local/bin/sops', '/usr/bin/sops') {
        return $_sops_cache = $p if -x $p;
    }
    return $_sops_cache = '';
}

sub _load_file_decrypted ($self, $file) {
    my $sops = $self->_sops_path;
    if ($sops && length($sops) && $file->slurp_utf8 =~ /sops:/) {
        my $yaml = `$sops decrypt $file 2>/dev/null`;
        return LoadFile(\$yaml) if $? == 0 && $yaml;
    }
    return LoadFile($file->stringify);
}

sub _load_all ($self) {
    my $dir = $self->_services_dir;

    # Fallback to services.yml for backwards compatibility
    unless ($dir->exists && $dir->children(qr/\.yml$/)) {
        return $self->_load_legacy;
    }

    my %services;
    for my $file (sort $dir->children(qr/\.yml$/)) {
        my $raw = $self->_load_file_decrypted($file);
        my $name = $raw->{name} // $file->basename('.yml');
        $services{$name} = $raw;
    }
    return \%services;
}

sub _load_legacy ($self) {
    my $file = path($self->app_home, 'services.yml');
    return {} unless $file->exists;
    my $data = LoadFile($file->stringify);
    my $svcs = $data->{services} // {};
    # Wrap legacy format into new structure
    my %out;
    for my $name (keys %$svcs) {
        my $svc = $svcs->{$name};
        $out{$name} = {
            name   => $name,
            repo   => $svc->{repo},
            branch => $svc->{branch},
            bin    => $svc->{bin},
            ($svc->{perlbrew} ? (perlbrew => $svc->{perlbrew}) : ()),
            targets => {
                live => {
                    port   => $svc->{port},
                    runner => $svc->{runner} // 'hypnotoad',
                    logs   => $svc->{logs} // {},
                    env    => $svc->{env} // {},
                },
            },
        };
    }
    return \%out;
}

sub services ($self) {
    return $self->_services;
}

sub service ($self, $name) {
    my $raw = $self->_services->{$name};
    return undef unless $raw;
    return $self->_resolve($name, $raw);
}

sub _resolve ($self, $name, $raw) {
    my $target_name = $self->target;
    my $targets = $raw->{targets} // {};
    my $target  = $targets->{$target_name} // $targets->{live} // {};

    return {
        name    => $name,
        repo    => $raw->{repo},
        branch  => $raw->{branch} // 'master',
        bin     => $raw->{bin},
        mode    => ($target->{runner} // 'hypnotoad') eq 'morbo' ? 'development' : 'production',
        runner  => $target->{runner} // 'hypnotoad',
        port    => $target->{port},
        logs    => $target->{logs} // {},
        env     => $target->{env} // {},
        host    => $target->{host} // 'localhost',
        ($target->{docs}  ? (docs  => $target->{docs})  : ()),
        ($target->{admin} ? (admin => $target->{admin}) : ()),
        ($raw->{perlbrew}  ? (perlbrew => $raw->{perlbrew}) : ()),
    };
}

sub service_names ($self) {
    return [ sort keys %{ $self->_services } ];
}

sub service_raw ($self, $name) {
    return $self->_services->{$name};
}

sub save_service ($self, $name, $data) {
    my $dir = $self->_services_dir;
    $dir->mkpath;
    $data->{name} = $name;
    my $file = $dir->child("$name.yml");
    DumpFile($file->stringify, $data);

    # Re-encrypt with SOPS if available
    my $sops = $self->_sops_path;
    if ($sops) {
        system($sops, 'encrypt', '-i', $file->stringify);
    }

    $self->reload;
    return $file;
}

sub delete_service ($self, $name) {
    my $file = $self->_services_dir->child("$name.yml");
    return 0 unless $file->exists;
    $file->remove;
    $self->reload;
    return 1;
}

sub load_secrets ($self, $name) {
    my $env_file = path($self->app_home, 'secrets', "$name.env");
    return {} unless $env_file->exists;

    my %env;
    for my $line ($env_file->lines_utf8({ chomp => 1 })) {
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) {
            $env{$1} = $2;
        }
    }
    return \%env;
}

sub dev_hostnames ($self) {
    my %seen;
    my @hosts;
    for my $name (@{ $self->service_names }) {
        my $dev = ($self->service_raw($name) || {})->{targets}{dev} or next;
        my $h = $dev->{host} or next;
        next if $h eq 'localhost';
        push @hosts, $h unless $seen{$h}++;
    }
    return [ sort @hosts ];
}

sub deploy_token ($self) {
    return $ENV{DEPLOY_TOKEN} if $ENV{DEPLOY_TOKEN};
    my $token_file = path($self->app_home, 'deploy_token.txt');
    return undef unless $token_file->exists;
    my $token = $token_file->slurp_utf8;
    $token =~ s/\s+$//;
    return $token;
}

1;
