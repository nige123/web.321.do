package Deploy::Config;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);
use Mojo::File qw(curfile);
use Deploy::Manifest;

has 'app_home'   => sub { $ENV{APP_HOME} // curfile->dirname->dirname->dirname };
has 'scan_dir'   => sub { $ENV{SCAN_DIR} // '/home/s3' };
has 'target'     => 'dev';
has '_services'  => sub ($self) { $self->_load_all };
has '_mtimes'    => sub { {} };

sub reload ($self) {
    $self->_services($self->_load_all);
    return $self;
}

sub _check_reload ($self) {
    my $base = path($self->scan_dir);
    return unless $base->exists;
    for my $dir (sort $base->children) {
        next unless $dir->is_dir;
        my $file = $dir->child('321.yml');
        next unless $file->exists;
        my $mtime = $file->stat->mtime;
        my $prev  = $self->_mtimes->{"$file"} // 0;
        if ($mtime > $prev) {
            $self->reload;
            return;
        }
    }
}

sub _load_all ($self) {
    my $base = path($self->scan_dir);
    return {} unless $base->exists;

    my %services;
    my %mtimes;
    for my $dir (sort $base->children) {
        next unless $dir->is_dir;
        my $file = $dir->child('321.yml');
        $mtimes{"$file"} = $file->stat->mtime if $file->exists;
        my $manifest = Deploy::Manifest->load($dir);
        next unless $manifest;
        $services{ $manifest->{name} } = $manifest;

        # Expand workers into separate service entries
        my $workers = $manifest->{workers} // {};
        my ($group) = split /\./, $manifest->{name}, 2;
        for my $worker_name (keys %$workers) {
            my $w = $workers->{$worker_name};
            my $full_name = "$group.$worker_name";
            $services{$full_name} = {
                %$manifest,
                name    => $full_name,
                entry   => $w->{cmd},
                runner  => 'script',
                health  => undef,
                workers => {},          # don't recurse
                _parent => $manifest->{name},
            };
        }
    }
    $self->_mtimes(\%mtimes);
    return \%services;
}

sub services ($self) {
    $self->_check_reload;
    return $self->_services;
}

sub service ($self, $name) {
    $self->_check_reload;
    my $manifest = $self->_services->{$name};
    return undef unless $manifest;
    return $self->_resolve($name, $manifest);
}

sub _resolve ($self, $name, $manifest) {
    my $target_name = $self->target;
    my $target = $manifest->{targets}{$target_name} // {};

    my $is_worker = $manifest->{runner} eq 'script';
    my $runner = $is_worker ? 'script' : ($target->{runner} // $manifest->{runner} // 'hypnotoad');

    return {
        name         => $name,
        repo         => $manifest->{repo},
        branch       => $manifest->{branch} // 'master',
        bin          => $manifest->{entry},
        mode         => $runner eq 'morbo' ? 'development' : 'production',
        runner       => $runner,
        port         => $is_worker ? undef : $target->{port},
        host         => $target->{host} // 'localhost',
        apt_deps     => $manifest->{apt_deps} // [],
        health       => $manifest->{health} // '/health',
        env_required => $manifest->{env_required} // {},
        env_optional => $manifest->{env_optional} // {},
        logs         => {
            stdout => "/tmp/$name.stdout.log",
            stderr => "/tmp/$name.stderr.log",
            ubic   => "/tmp/$name.ubic.log",
        },
        ($manifest->{test}     ? (test     => $manifest->{test})     : ()),
        ($manifest->{favicon}  ? (favicon  => $manifest->{favicon})  : ()),
        ($target->{ssh}        ? (ssh      => $target->{ssh})        : ()),
        ($target->{ssh_key}    ? (ssh_key  => $target->{ssh_key})    : ()),
        ($target->{docs}       ? (docs     => $target->{docs})       : ()),
        ($target->{admin}      ? (admin    => $target->{admin})      : ()),
        ($manifest->{perl}     ? (perlbrew => $manifest->{perl})     : ()),
        ($target->{env}        ? (env      => $target->{env})        : (env => {})),
    };
}

sub service_names ($self) {
    return [ sort keys %{ $self->_services } ];
}

sub service_raw ($self, $name) {
    return $self->_services->{$name};
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
        my $manifest = $self->_services->{$name};
        my $dev = $manifest->{targets}{dev} or next;
        my $h = $dev->{host} or next;
        next if $h eq 'localhost';
        push @hosts, $h unless $seen{$h}++;
    }
    return [ sort @hosts ];
}

1;
