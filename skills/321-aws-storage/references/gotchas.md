# Gotchas - each of these has burned real time

## Don't hand-roll SigV4 policy signing

The single biggest failure mode: agents assume CPAN has no presigned-POST
support and write ~100 lines of HMAC-SHA256 chain, canonical encoding, and
policy JSON by hand. `Amazon::S3::Thin->generate_presigned_post($bucket,
$key, \@fields, \@conditions, $expires_in)` does all of it. Hand-rolled
signing works until an encoding edge case (space in filename, `+` in a key)
produces a `SignatureDoesNotMatch` that takes hours to diff against the AWS
canonical form. Use the module.

## upload_fields is an ordered arrayref, NOT a hash

`generate_presigned_post` returns `{url, fields}` where `fields` is an
arrayref of key/value pairs in order. Keep it that way through your JSON
contract. Two failure modes when you "clean it up" into a hash:

- Perl hash ordering randomises per process; some S3 deployments and
  S3-compatible stores care about field order relative to the policy.
- The browser MUST append the `file` field **after** every policy field.
  S3 ignores anything after `file` - a signature field appended after the
  file silently fails with 403 Access Denied.

Browser side, iterate pairwise:

```js
var fields = data.upload_fields || [];
for (var i = 0; i < fields.length; i += 2) fd.append(fields[i], fields[i + 1]);
fd.append('file', file);   // LAST, always
```

## Every form field needs a matching policy condition

S3 rejects the POST if a non-exempt form field has no condition in the
policy (`Invalid according to Policy: Policy Condition failed` or a bare
403). The template passes `Content-Type` in both the fields arrayref AND as
an `['eq', '$Content-Type', $content_type]` condition - if you add a field
(e.g. `x-amz-server-side-encryption` for a KMS bucket), add the matching
condition too.

## file_size from the client is a claim, not a fact

The sign endpoint validates `file_size` before signing - but the client
declared that number. The policy locks `Content-Type`, not size. To make S3
itself enforce the cap, pass `max_bytes` to the service class so the policy
includes `['content-length-range', 1, $max_bytes]` (supported by the same
generate_presigned_post conditions arrayref). Without it, a hostile client
that got a signature can upload a 5 GB "photo".

## us-east-1 host quirk

Regional bucket hosts are `bucket.s3.<region>.amazonaws.com` - EXCEPT
us-east-1, which is plain `bucket.s3.amazonaws.com`. The `_bucket_host`
method in the template handles this; keep it when porting.

## CORS is required for the upload POST, not for serving

The browser XHR to S3 is cross-origin. Without a CORS policy on the bucket
the preflight fails and every upload dies with a network error (often
misread as a signing bug). Minimum block:

```json
[{
  "AllowedOrigins": ["https://app.example.com"],
  "AllowedMethods": ["POST"],
  "AllowedHeaders": ["*"],
  "ExposeHeaders":  ["ETag"],
  "MaxAgeSeconds":  3000
}]
```

Plain `<img>`/`<video>` GETs of public objects need no CORS at all. Add the
dev hostname to AllowedOrigins or uploads will only work in production.

## Validate BEFORE signing, on the server

The sign endpoint is the security boundary. Allowlist extension AND
content-type AND size per media kind server-side (see the controller
template's `_validate_media_file`). Never sign whatever the client asked
for - a signature is a capability.

## The server names the object, never the client

Build keys as `<prefix>/<owner-token>/<kind>-<nanoid32>.<ext>` where the
extension is sanitised (`s/[^a-z0-9]//g`) from the filename and everything
else is server-generated. Client filenames in keys = path traversal invites,
collisions, and unicode grief. Unguessable keys are also what makes the
public-objects serving model safe.

## Expiry must cover the whole upload

The presign expiry (default 900 s in the template) gates when the upload may
START and finish. A 50 MB video on slow mobile can take minutes - don't
"tighten security" down to 60 s or real users on trains start failing.

## Clock skew

SigV4 tolerates ~15 minutes of skew. If every signature is suddenly
rejected with `RequestTimeTooSkewed`, check NTP on the app host before
debugging code.

## delete is best-effort

`delete_object` wraps the call in `eval { ... } or warn`. A user deleting
their message must succeed even if S3 is briefly unreachable - orphaned
objects are a cleanup-job problem, not a user-facing error.

## Content-Type is stored, not verified

S3 records the declared content type without inspecting bytes. A hostile
client can upload an executable labelled `image/webp`. Harmless when the
only consumer is a browser `<img>` (it just won't render), but if the app
ever processes the media server-side (Imager, ffmpeg), magic-byte check
first.
