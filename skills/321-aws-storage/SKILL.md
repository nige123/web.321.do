---
name: 321-aws-storage
description: Use when a Perl Mojolicious app needs browser file uploads stored in AWS S3 - photos, video, voice notes, attachments - without the file bytes passing through the app server, or when working with Amazon::S3::Thin, generate_presigned_post, presigned POST policies, S3 CORS for uploads, direct-to-S3 XHR upload JavaScript, or S3 object cleanup from Perl.
---

# Direct-to-S3 uploads via presigned POST (Amazon::S3::Thin)

## Overview

Browser uploads go **straight to S3**; the Perl app only signs permission
slips. This matters on a preforking hypnotoad deployment: a 25 MB voice note
on hotel wifi would hold a worker hostage for minutes. Instead:

```
1. browser  POST /create-upload (metadata only)   -> app validates, signs
2. app      returns JSON {upload_url, upload_fields, s3_key}
3. browser  XHR POST multipart to S3 directly     (fields first, file LAST)
4. browser  submits the normal form with s3_key values in hidden inputs
5. app      stores the keys; serves media via public_base_url later
```

**Do not hand-roll SigV4 policy signing.** `Amazon::S3::Thin` ships
`generate_presigned_post` - policy-based signing in one call. Agents who
don't know this write 100 lines of HMAC chains from scratch; the module is
maintained, tested, and already handles the canonical encoding traps.

`templates/S3Uploads.pm` is the real, production-proven service class (from
love.honeywillow.com) - port it and rename the package. The controller and
browser-side patterns live in `templates/` too.

**Read `references/gotchas.md` first** - the field-ordering trap (fields are
an ordered arrayref, NOT a hash; `file` must be appended last), policy/field
mismatch failures, the us-east-1 host quirk, CORS-only-for-POST, lying
`file_size`, and orphan cleanup are all there.

## When to use

- A Mojolicious app (AXS baseline or otherwise) where users attach files to
  a server-rendered form: photos, video, audio, documents.
- Any work on an existing `create-upload` / `S3Uploads`-style layer: adding
  a media kind, changing size limits, debugging a 403 from S3.
- NOT for server-generated files (reports, exports) - the server can just
  `put_object` directly with Amazon::S3::Thin; no presigning needed.

## The pieces

| Piece | Template | Role |
|---|---|---|
| Service class | `templates/S3Uploads.pm` | wraps Amazon::S3::Thin; returns `{error=>...}` hashrefs, never dies in request path |
| Sign endpoint | `templates/create-upload-controller.pm` | validates kind/extension/content-type/size BEFORE signing; builds nanoid key; returns the JSON contract |
| Browser JS | `templates/upload.js` | fetch sign endpoint -> XHR to S3 with progress -> hidden `media_keys` inputs |
| Config | below | per-environment credentials block |

## Config + helper wiring

```perl
# conf/production.conf
s3_uploads => {
    access_key_id     => 'AKIA...',
    secret_access_key => '...',
    bucket            => 'myapp-media',
    region            => 'eu-west-1',
    public_base_url   => 'https://myapp-media.s3.eu-west-1.amazonaws.com',
},
```

```perl
# in startup
$self->helper('s3_uploads' => sub {
    state $s3 = MyApp::S3Uploads->new(
        aws_access_key_id     => $self->config->{s3_uploads}{access_key_id},
        aws_secret_access_key => $self->config->{s3_uploads}{secret_access_key},
        bucket                => $self->config->{s3_uploads}{bucket},
        region                => $self->config->{s3_uploads}{region},
        public_base_url       => $self->config->{s3_uploads}{public_base_url},
    );
    return $s3;
});
```

cpanfile: `Amazon::S3::Thin`, `Net::Amazon::Signature::V4` (Thin's signing
dep), `Nanoid` (unguessable object keys).

## The JSON contract (sign endpoint -> browser)

```json
{ "ok": true,
  "s3_key": "messages/<owner-token>/image-<nanoid32>.jpg",
  "upload_method": "POST",
  "upload_url": "https://myapp-media.s3.eu-west-1.amazonaws.com/",
  "upload_fields": ["key", "...", "policy", "...", "x-amz-signature", "..."],
  "max_bytes": 10485760,
  "expires_in": 900 }
```

`upload_fields` is a FLAT ORDERED LIST of key/value pairs. The browser appends
them pairwise to a FormData, then appends `file` last, then XHRs to
`upload_url`. On success it records `s3_key` in a hidden input; the real form
never carries bytes.

## Serving what was uploaded

Two options; pick one deliberately:

- **Public objects, unguessable keys** (house default): keys embed a
  32-char nanoid under the owner's token prefix; bucket allows public GET but
  never ListBucket. `public_url` on the service class builds
  `public_base_url/key`. Zero CORS or expiry pain for `<img>`/`<video>`.
- **Private bucket + presigned GET**: when content is sensitive enough that
  an unguessable URL is not acceptable (it can be reshared). Costs you URL
  expiry management on every render.

## AWS-side setup (once per bucket)

1. Bucket in one region; Object Ownership = bucket owner enforced (no ACLs).
2. **CORS on the bucket** - browser POSTs are cross-origin (see gotchas for
   the JSON block). Plain `<img>` GETs need no CORS.
3. Dedicated IAM user scoped to `PutObject/GetObject/DeleteObject` on the
   bucket's upload prefix; its keys go in the config block.

## Deleting

`delete_object` on the service class is best-effort: `eval` + `warn`, never
die - a failed S3 cleanup must not break a user-facing delete flow. Users
abandon forms, so uploaded-but-never-attached objects accumulate: sweep them
with a nightly job or an S3 lifecycle rule on an `incoming/` prefix.

## Testing

Follow the house pattern (love.honeywillow.com `t/06-s3-uploads.t`):
`skip_all` when config has no real credentials; otherwise construct the
service from app config, generate a presigned POST live, and assert the
contract shape (url host, ordered fields include policy + x-amz-signature,
Content-Type locked). No actual upload needed in CI.
