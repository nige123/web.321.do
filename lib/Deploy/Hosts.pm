package Deploy::Hosts;

use Mojo::Base -base, -signatures;
use Path::Tiny ();

has 'path' => '/etc/hosts';

my $BEGIN = '# BEGIN 321.do managed';
my $END   = '# END 321.do managed';
my $HOST_RE = qr/^[a-zA-Z0-9]([a-zA-Z0-9\-\.]*[a-zA-Z0-9])?$/;

sub _strip_block ($self, $content) {
    $content =~ s/\Q$BEGIN\E\n.*?\Q$END\E\n?//s;
    return $content;
}

sub _build_block ($self, $hosts) {
    return '' unless @$hosts;
    my @lines = map { "127.0.0.1  $_" } @$hosts;
    return "$BEGIN\n" . join("\n", @lines) . "\n$END\n";
}

sub read ($self) {
    my $file = Path::Tiny::path($self->path);
    return [] unless $file->exists;
    my $content = $file->slurp_utf8;
    return [] unless $content =~ /\Q$BEGIN\E\n(.*?)\Q$END\E/s;
    my $body = $1;
    my @hosts;
    for my $line (split /\n/, $body) {
        push @hosts, $2 if $line =~ /^(\S+)\s+(\S+)/;
    }
    return \@hosts;
}

sub write ($self, $hosts) {
    for my $h (@$hosts) {
        die "invalid hostname '$h'\n" unless $h =~ $HOST_RE;
    }

    my $file = Path::Tiny::path($self->path);
    my $content = $file->exists ? $file->slurp_utf8 : '';
    $content = $self->_strip_block($content);
    $content =~ s/\n*\z/\n/;  # ensure single trailing newline before block
    my $block = $self->_build_block($hosts);
    $content .= $block if length $block;

    $file->spew_utf8($content);
}

1;
