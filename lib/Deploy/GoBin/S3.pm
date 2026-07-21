package Deploy::GoBin::S3;

use Mojo::Base -base, -signatures;
use Path::Tiny qw(tempfile);

# S3 boundary for 321 gobin: shells to the aws CLI. Credentials travel in the
# child environment, never on the command line - argv is visible in ps and in
# logs, the env is not. The exec coderef is injectable so tests assert the
# exact command lines without the CLI or network present.

has [qw(bucket creds)];
has exec => sub ($self) { \&_shell_exec };

sub _env ($self) {
    my $c = $self->creds // {};
    return {
        AWS_ACCESS_KEY_ID     => $c->{s3_access_key_id}     // '',
        AWS_SECRET_ACCESS_KEY => $c->{s3_secret_access_key} // '',
    };
}

sub put ($self, %a) {
    my $cmd = "aws s3api put-object --bucket @{[ $self->bucket ]} --key $a{key}";
    my $tmp;   # keeps a content temp file alive until exec returns
    if (defined $a{file}) {
        $cmd .= " --body $a{file}";
    } else {
        $tmp = tempfile();
        $tmp->spew_raw($a{content} // '');
        $cmd .= " --body $tmp";
    }
    $cmd .= " --content-type $a{content_type}" if $a{content_type};
    my $r = $self->exec->(cmd => $cmd, env => $self->_env, dir => undef);
    return { ok => $r->{ok} ? 1 : 0 };
}

sub head ($self, %a) {
    my $r = $self->exec->(
        cmd => "aws s3api head-object --bucket @{[ $self->bucket ]} --key $a{key}",
        env => $self->_env, dir => undef,
    );
    return { ok => $r->{ok} ? 1 : 0 };
}

sub get ($self, %a) {
    my $out = tempfile();
    my $r = $self->exec->(
        cmd => "aws s3api get-object --bucket @{[ $self->bucket ]} --key $a{key} $out",
        env => $self->_env, dir => undef,
    );
    return { ok => 0, content => undef } unless $r->{ok};
    return { ok => 1, content => $out->slurp_raw };
}

sub _shell_exec (%a) {
    local %ENV = (%ENV, %{ $a{env} // {} });
    my $cmd = $a{cmd};
    $cmd = "cd $a{dir} && $cmd" if $a{dir};
    my $output = `$cmd 2>&1`;
    return { ok => ($? == 0 ? 1 : 0), output => $output };
}

1;
