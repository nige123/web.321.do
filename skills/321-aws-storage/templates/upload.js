// Direct-to-S3 upload (presigned POST) - browser side.
// Production-proven pattern from love.honeywillow.com contribute/write.html.ep.
//
// Flow: sign via our app -> XHR multipart straight to S3 -> record s3_key in
// a hidden input on the real form. The file input has no name attribute, so
// bytes never ride the form POST.
//
// Adapt: createUploadUrl (the sign endpoint), form/input element ids, and
// how you render previews / hidden fields.

(function () {
    var createUploadUrl = '/create-upload';       // sign endpoint for this page
    var form      = document.getElementById('main-form');
    var fileInput = document.getElementById('file-input');   // <input type="file" multiple> - NO name attr
    var uploads   = [];                                       // {s3_key, mime}
    var uploading = 0;

    function uploadFile(file) {
        uploading++;

        var body = new FormData();
        body.append('media_kind', kindFor(file));             // image | voice | video
        body.append('filename', file.name);
        body.append('content_type', file.type);
        body.append('file_size', file.size);

        fetch(createUploadUrl, { method: 'POST', body: body })
            .then(function (res) { return res.json(); })
            .then(function (data) {
                if (!data.ok) {
                    var msg = data.errors ? Object.values(data.errors).join(' ')
                                          : (data.error || 'Upload failed.');
                    throw new Error(msg);
                }
                return uploadToS3(data, file);
            })
            .then(function (data) {
                uploads.push({ s3_key: data.s3_key, mime: file.type });
                syncHiddenFields();
                done();
            })
            .catch(function (err) {
                showError(err.message || 'Upload failed. Please try again.');
                done();
            });
    }

    function uploadToS3(data, file) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open(data.upload_method, data.upload_url, true);

            xhr.upload.addEventListener('progress', function (e) {
                if (e.lengthComputable) {
                    showProgress(Math.round((e.loaded / e.total) * 100));
                }
            });
            xhr.addEventListener('load', function () {
                xhr.status < 400 ? resolve(data)
                                 : reject(new Error('Upload failed. Please try again.'));
            });
            xhr.addEventListener('error', function () {
                reject(new Error('Upload failed. Please check your connection and try again.'));
            });

            // upload_fields is a FLAT ORDERED LIST of key/value pairs.
            // Append pairwise, in order; the file field MUST come last -
            // S3 ignores everything after it.
            var fields = data.upload_fields || [];
            var fd = new FormData();
            for (var i = 0; i < fields.length; i += 2) {
                fd.append(fields[i], fields[i + 1]);
            }
            fd.append('file', file);
            xhr.send(fd);
        });
    }

    // The real form carries only keys, never bytes
    function syncHiddenFields() {
        form.querySelectorAll('input[name=media_keys], input[name=media_mimes]')
            .forEach(function (el) { el.remove(); });
        uploads.forEach(function (u) {
            form.appendChild(hidden('media_keys',  u.s3_key));
            form.appendChild(hidden('media_mimes', u.mime));
        });
    }

    function hidden(name, value) {
        var el = document.createElement('input');
        el.type = 'hidden';
        el.name = name;
        el.value = value;
        return el;
    }

    function done() {
        uploading = Math.max(0, uploading - 1);
    }

    fileInput.addEventListener('change', function () {
        for (var i = 0; i < fileInput.files.length; i++) uploadFile(fileInput.files[i]);
        fileInput.value = '';
    });

    // Block submit while uploads are in flight
    form.addEventListener('submit', function (e) {
        if (uploading > 0) e.preventDefault();
    });

    // Site-specific: implement kindFor(file) (map file.type to image/voice/video),
    // showProgress(pct), showError(msg). Consider client-side image resize
    // (canvas to ~1600px) before upload - phones produce 8 MB photos nobody needs.
})();
