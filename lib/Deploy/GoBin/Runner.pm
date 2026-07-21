package Deploy::GoBin::Runner;

use Mojo::Base -base, -signatures;

# GoReleaser boundary for 321 gobin. The build env (CGO_ENABLED, the version
# stamp, GOBIN_SIGNING_KEY) merges into the child environment - the signing
# key must never appear on the command line or in logs. The exec coderef is
# injectable so tests assert the exact invocation without the toolchain.

has exec => sub ($self) { \&_shell_exec };

sub run ($self, %a) {
    return $self->exec->(
        cmd => "goreleaser release --clean -f $a{config}",
        dir => $a{dir},
        env => $a{env} // {},
    );
}

sub _shell_exec (%a) {
    local %ENV = (%ENV, %{ $a{env} // {} });
    my $cmd = $a{cmd};
    $cmd = "cd $a{dir} && $cmd" if $a{dir};
    my $output = `$cmd 2>&1`;
    return { ok => ($? == 0 ? 1 : 0), output => $output };
}

1;
