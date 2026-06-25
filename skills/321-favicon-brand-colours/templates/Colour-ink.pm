package F6::Util::Colour;

#------------------------------------------------------------------------------
# Nigel Hamilton
#
# Filename:     Colour.pm
# Description:  Pick a legible tile text ("ink") colour for a background accent.
#------------------------------------------------------------------------------

use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(ink_for);

#------------------------------------------------------------------------------
# _rel_lum - WCAG relative luminance (0..1) for a '#rrggbb' (or 'rrggbb').
#------------------------------------------------------------------------------
sub _rel_lum ($hex) {
    my @c = ($hex =~ /([0-9a-fA-F]{2})/g);
    return 0 unless @c >= 3;
    my @l = map {
        my $v = hex($_) / 255;
        $v <= 0.03928 ? $v / 12.92 : (($v + 0.055) / 1.055) ** 2.4;
    } @c[0, 1, 2];
    return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2];
}

sub _contrast ($l1, $l2) {
    my ($hi, $lo) = $l1 > $l2 ? ($l1, $l2) : ($l2, $l1);
    return ($hi + 0.05) / ($lo + 0.05);
}

my $PAPER_LUM = _rel_lum('F4EFE5');   # --paper, the default light tile text
my $AA_LARGE  = 3.0;                  # WCAG AA for large/bold text

#------------------------------------------------------------------------------
# ink_for - best tile ink for a background hex: 'paper' (the default light
#   text) UNLESS paper text would fail WCAG AA-large (3:1) on it, in which case
#   'ink' (the dark text). So the brand's white-on-vibrant look is preserved,
#   and only genuinely low-contrast accents (light greens / yellows / ambers)
#   flip to dark text.
#------------------------------------------------------------------------------
sub ink_for ($hex) {
    return 'paper' unless defined $hex && $hex =~ /[0-9a-fA-F]{6}/;
    return _contrast($PAPER_LUM, _rel_lum($hex)) >= $AA_LARGE ? 'paper' : 'ink';
}

1;
