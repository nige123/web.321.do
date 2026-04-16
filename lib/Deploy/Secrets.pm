package Deploy::Secrets;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(path);
use POSIX qw(strftime);

has 'app_home';

my $KEY_RE = qr/^[A-Z_][A-Z0-9_]*$/;

sub _env_file ($self, $name) {
    return path($self->app_home, 'secrets', "$name.env");
}

sub _audit_file ($self, $name) {
    return path($self->app_home, 'secrets', "$name.audit.log");
}

sub _read ($self, $name) {
    my $file = $self->_env_file($name);
    return {} unless $file->exists;
    my %env;
    for my $line ($file->lines_utf8({ chomp => 1 })) {
        next if $line =~ /^\s*(#|$)/;
        if ($line =~ /^([A-Z_][A-Z0-9_]*)=(.*)$/) {
            $env{$1} = $2;
        }
    }
    return \%env;
}

sub _write_atomic ($self, $name, $env) {
    my $file = $self->_env_file($name);
    $file->parent->mkpath;
    my $tmp  = path($file->parent, "$name.env.tmp.$$");
    my @lines = map { "$_=$env->{$_}" } sort keys %$env;
    $tmp->spew_utf8(join("\n", @lines) . (@lines ? "\n" : ''));
    chmod 0600, "$tmp" or die "chmod: $!";
    rename "$tmp", "$file" or die "rename: $!";
}

sub _audit ($self, $name, $actor, $action, $key) {
    my $log = $self->_audit_file($name);
    my $ts  = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    $log->append_utf8("$ts $actor $action $key\n");
    chmod 0600, "$log";
}

sub diff ($self, $name, $manifest_env) {
    my $env      = $self->_read($name);
    my %required = %{ $manifest_env->{required} // {} };
    my %optional = %{ $manifest_env->{optional} // {} };

    my @missing = grep { !exists $env->{$_} } sort keys %required;
    my @present = grep {  exists $env->{$_} } sort keys %required;
    my @opt_set = grep {  exists $env->{$_} } sort keys %optional;

    return { missing => \@missing, present => \@present, optional_set => \@opt_set };
}

sub set ($self, $name, $key, $value, %opts) {
    die "invalid key '$key'\n" unless $key =~ $KEY_RE;
    die "newline not allowed in value\n" if $value =~ /[\r\n]/;
    my $actor = $opts{actor} // 'unknown';

    my $env = $self->_read($name);
    $env->{$key} = $value;
    $self->_write_atomic($name, $env);
    $self->_audit($name, $actor, 'set', $key);
}

sub delete ($self, $name, $key, %opts) {
    die "invalid key '$key'\n" unless $key =~ $KEY_RE;
    my $actor = $opts{actor} // 'unknown';

    my $env = $self->_read($name);
    return unless exists $env->{$key};
    delete $env->{$key};
    $self->_write_atomic($name, $env);
    $self->_audit($name, $actor, 'delete', $key);
}

1;
