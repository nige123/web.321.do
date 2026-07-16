package MyApp::Controller::Uploads;

#------------------------------------------------------------------------------
# create-upload sign endpoint - validate, name the object, presign
#
# The security boundary. Allowlist kind/extension/content-type/size BEFORE
# signing (a signature is a capability), and the SERVER names the object -
# the client filename only ever contributes a sanitised extension.
#
# Route (behind whatever auth/token filter owns the upload):
#   $r->post('/create-upload')->to('uploads#create_upload');
#------------------------------------------------------------------------------

use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(true false);


my %ALLOWED = (
    image => {
        extensions    => { map { $_ => 1 } qw(jpg jpeg png gif webp) },
        content_types => { map { $_ => 1 } qw(image/jpeg image/png image/gif image/webp) },
        max_bytes     => 10 * 1024 * 1024,
        label         => 'photo',
    },
    voice => {
        extensions    => { map { $_ => 1 } qw(m4a mp3 wav) },
        content_types => { map { $_ => 1 }
            qw(audio/m4a audio/mp4 audio/mpeg audio/mp3 audio/wav audio/x-wav audio/wave) },
        max_bytes     => 25 * 1024 * 1024,
        label         => 'voice note',
    },
    video => {
        extensions    => { map { $_ => 1 } qw(mp4 mov m4v) },
        content_types => { map { $_ => 1 } qw(video/mp4 video/quicktime video/x-m4v) },
        max_bytes     => 50 * 1024 * 1024,
        label         => 'video',
    },
);


#------------------------------------------------------------------------------
# create_upload - POST, expects: media_kind, filename, content_type, file_size
#------------------------------------------------------------------------------

sub create_upload ($self) {

    # adapt: whatever establishes ownership on this route (token, session)
    my $owner_token = $self->stash('owner_token') // '';

    my $media_kind   = lc($self->param('media_kind')   // '');
    my $filename     = $self->param('filename')        // '';
    my $content_type = lc($self->param('content_type') // '');
    my $file_size    = int($self->param('file_size')   // 0);

    $filename =~ s/^\s+|\s+$//g;
    $filename =~ s/\0//g;

    my %errors;

    $errors{media_kind} = 'Unsupported media type.'
        unless $ALLOWED{$media_kind};

    $errors{filename} = 'Please provide a filename.'
        unless length $filename;

    $errors{file_size} = 'Please provide a valid file size.'
        unless $file_size > 0;

    if (my $rule = $ALLOWED{$media_kind}) {

        my ($ext) = lc($filename) =~ /\.([a-z0-9]+)\z/;

        $errors{media_file} = "Please upload a supported $rule->{label} file."
            unless $ext && $rule->{extensions}{$ext};

        $errors{media_file} = "That $rule->{label} file is too large."
            if $file_size > $rule->{max_bytes};

        $errors{media_file} = "Please upload a supported $rule->{label} file."
            if length $content_type && !$rule->{content_types}{$content_type};
    }

    return $self->render(status => 422, json => { ok => false, errors => \%errors })
        if %errors;

    my $s3_key = $self->_build_s3_key(
        owner_token => $owner_token,
        media_kind  => $media_kind,
        filename    => $filename,
    );

    my $result = $self->s3_uploads->create_presigned_post({
        key          => $s3_key,
        content_type => $content_type,
        expires_in   => 900,
        max_bytes    => $ALLOWED{$media_kind}{max_bytes},
    });

    return $self->render(status => 500, json => { ok => false, error => $result->{error} })
        if $result->{error};

    return $self->render(json => {
        ok             => true,
        media_kind     => $media_kind,
        s3_key         => $s3_key,
        upload_method  => $result->{upload_method},
        upload_url     => $result->{upload_url},
        upload_fields  => $result->{upload_fields}  || [],
        upload_headers => $result->{upload_headers} || {},
        max_bytes      => $ALLOWED{$media_kind}{max_bytes},
        expires_in     => $result->{expires_in} || 900,
    });
}


#------------------------------------------------------------------------------
# _build_s3_key - <prefix>/<owner-token>/<kind>-<nanoid32>.<ext>
#
# Server-named, unguessable. Only the sanitised extension comes from the
# client filename.
#------------------------------------------------------------------------------

sub _build_s3_key ($self, %args) {

    require Nanoid;

    my $ext = lc($args{filename});
    $ext =~ s/^.*\.//;
    $ext =~ s/[^a-z0-9]//g;

    my $token    = Nanoid::generate(size => 32);
    my $basename = join '-', $args{media_kind}, $token;
    my $object   = length($ext) ? "$basename.$ext" : $basename;

    return join '/', 'uploads', $args{owner_token}, $object;
}


1;
