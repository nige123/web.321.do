package MyApp::S3Uploads;

#------------------------------------------------------------------------------
# S3Uploads.pm - presigned S3 uploads via Amazon::S3::Thin
#
# Production-proven service class (from love.honeywillow.com). Port it and
# rename the package. Request-path methods return {error => ...} hashrefs
# rather than dying; construction problems surface as missing-attribute
# errors on first use.
#------------------------------------------------------------------------------

use Mojo::Base -base, -signatures;

use Carp qw(croak);


has aws_access_key_id     => '';
has aws_secret_access_key => '';
has bucket                => '';
has expires_in            => 900;
has public_base_url       => '';
has region                => '';


#------------------------------------------------------------------------------
# create_presigned_post - presigned POST for browser direct upload
#
# Args hashref: key (required), content_type, expires_in, max_bytes
# Returns: { upload_method, upload_url, upload_fields, upload_headers,
#            bucket, region, expires_in }  or  { error => '...' }
#------------------------------------------------------------------------------

sub create_presigned_post ($self, $args) {

    croak 'create_presigned_post requires a hashref'
        unless ref $args eq 'HASH';

    my $content_type = $args->{content_type} // 'application/octet-stream';
    my $expires_in   = $args->{expires_in}   // $self->expires_in;
    my $key          = $args->{key}          // '';
    my $max_bytes    = $args->{max_bytes}    // 0;

    return { error => 'Missing S3 key.' }
        unless length $key;

    for my $attr (qw(aws_access_key_id aws_secret_access_key bucket region)) {
        return { error => "Missing required S3Uploads attribute: $attr" }
            unless length $self->$attr;
    }

    my $result = eval {
        $self->_generate_presigned_post(
            content_type => $content_type,
            expires_in   => $expires_in,
            key          => $key,
            max_bytes    => $max_bytes,
        );
    };

    if (my $error = $@) {
        chomp $error;
        return { error => "Failed to create presigned upload: $error" };
    }

    return $result;
}


#------------------------------------------------------------------------------
# _generate_presigned_post - call Amazon::S3::Thin
#
# Every form field must have a matching policy condition or S3 rejects the
# POST. content-length-range makes S3 itself enforce the size cap - the
# client-declared file_size validated at the sign endpoint is only a claim.
#------------------------------------------------------------------------------

sub _generate_presigned_post ($self, %args) {

    require Amazon::S3::Thin;

    my $content_type = $args{content_type};
    my $expires_in   = $args{expires_in};
    my $key          = $args{key};
    my $max_bytes    = $args{max_bytes};

    my $s3 = Amazon::S3::Thin->new({
        aws_access_key_id     => $self->aws_access_key_id,
        aws_secret_access_key => $self->aws_secret_access_key,
        region                => $self->region,
        secure                => 1,
    });

    my @conditions = (
        ['eq', '$Content-Type', $content_type],
    );

    push @conditions, ['content-length-range', 1, $max_bytes]
        if $max_bytes > 0;

    my $presigned = $s3->generate_presigned_post(
        $self->bucket,
        $key,
        [
            'Content-Type' => $content_type,
        ],
        \@conditions,
        $expires_in,
    );

    # fields is an ORDERED arrayref of key/value pairs - keep it that way;
    # the browser appends them in order and the file field must come last
    my @fields = @{ $presigned->{fields} // [] };

    return {
        bucket         => $self->bucket,
        expires_in     => $expires_in,
        region         => $self->region,
        upload_fields  => \@fields,
        upload_headers => {},
        upload_method  => 'POST',
        upload_url     => $presigned->{url},
    };
}


#------------------------------------------------------------------------------
# public_url - build a public URL for an S3 key
#------------------------------------------------------------------------------

sub public_url ($self, $key) {

    return '' unless defined $key && length $key;

    if (length $self->public_base_url) {
        my $base = $self->public_base_url;
        $base =~ s{/\z}{};
        return "$base/$key";
    }

    my $host = $self->_bucket_host($self->bucket, $self->region);

    return "https://$host/$key";
}


#------------------------------------------------------------------------------
# delete_object - remove a file from S3 (best-effort: warn, never die)
#------------------------------------------------------------------------------

sub delete_object ($self, $key) {

    return unless defined $key && length $key;

    require Amazon::S3::Thin;

    my $s3 = Amazon::S3::Thin->new({
        aws_access_key_id     => $self->aws_access_key_id,
        aws_secret_access_key => $self->aws_secret_access_key,
        region                => $self->region,
        secure                => 1,
    });

    eval { $s3->delete_object($self->bucket, $key); 1 }
        or warn "S3 delete failed for $key: $@";

    return;
}


#------------------------------------------------------------------------------
# _bucket_host - derive regional bucket hostname
#
# us-east-1 quirk: no region segment in the host
#------------------------------------------------------------------------------

sub _bucket_host ($self, $bucket_name, $region) {

    return "$bucket_name.s3.amazonaws.com"
        if !defined $region || $region eq '' || $region eq 'us-east-1';

    return "$bucket_name.s3.$region.amazonaws.com";
}


1;
