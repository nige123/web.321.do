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

    if ($self->_writable) {
        $file->spew_utf8($content);
    }
    else {
        # /etc/hosts is root-owned — stage the new file and sudo it into place.
        require File::Temp;
        my $tmp = File::Temp->new;
        binmode $tmp, ':encoding(UTF-8)';
        print $tmp $content;
        close $tmp;
        system('sudo', 'cp', $tmp->filename, "$file") == 0
            or die "failed to write $file (needs sudo)\n";
    }
}

sub _writable ($self) {
    my $p = $self->path;
    return -w $p if -e $p;
    return -w Path::Tiny::path($p)->parent->stringify;
}

# Reconcile the managed block with the desired host list. No-op (and no sudo
# prompt) when they already match, so it's cheap to call on every deploy.
# Returns 1 if it changed anything, 0 otherwise.
sub sync ($self, $wanted) {
    my $have = join "\0", sort @{ $self->read };
    my %seen;
    my @want = grep { !$seen{$_}++ } @$wanted;
    return 0 if $have eq join "\0", sort @want;
    $self->write([ sort @want ]);
    return 1;
}

1;
