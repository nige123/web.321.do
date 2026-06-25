// Passkeys (WebAuthn) client module - progressive enhancement.
// Controls carrying [data-passkey-login] / [data-passkey-register] are wired
// only when the browser supports WebAuthn; [data-passkey-only] elements are
// revealed and [data-passkey-fallback] elements hidden once support is known.
// Drop this into your app's JS bundle (its own IIFE - safe to append).
// Optional: window.<app>Toast(msg) for user-facing errors; guarded below.
(function () {
    "use strict";
    if (!window.PublicKeyCredential || !navigator.credentials) return;

    function b64uToBuf(s) {
        s = s.replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        var bin = atob(s), buf = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
        return buf.buffer;
    }
    function bufToB64u(buf) {
        var bytes = new Uint8Array(buf), bin = '';
        for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }
    function postJSON(url, body) {
        return fetch(url, {
            method: 'POST',
            credentials: 'same-origin',
            headers: body ? { 'Content-Type': 'application/json' } : {},
            body: body ? JSON.stringify(body) : undefined
        }).then(function (r) { return r.json(); });
    }
    function toast(msg) { if (window.favsixToast) favsixToast(msg); }

    document.querySelectorAll('[data-passkey-only]').forEach(function (el) { el.hidden = false; });
    document.querySelectorAll('[data-passkey-fallback]').forEach(function (el) { el.hidden = true; });

    function assertionToJSON(cred) {
        return { id: cred.id, type: cred.type, response: {
            clientDataJSON:    bufToB64u(cred.response.clientDataJSON),
            authenticatorData: bufToB64u(cred.response.authenticatorData),
            signature:         bufToB64u(cred.response.signature)
        } };
    }
    function attestationToJSON(cred) {
        return { id: cred.id, type: cred.type,
            transports: (cred.response.getTransports && cred.response.getTransports()) || [],
            response: {
                clientDataJSON:    bufToB64u(cred.response.clientDataJSON),
                attestationObject: bufToB64u(cred.response.attestationObject)
            } };
    }

    function signInWithPasskey(btn) {
        btn.disabled = true;
        postJSON('/auth/passkey/login/options').then(function (opts) {
            opts.challenge = b64uToBuf(opts.challenge);
            (opts.allowCredentials || []).forEach(function (c) { c.id = b64uToBuf(c.id); });
            return navigator.credentials.get({ publicKey: opts });
        }).then(function (cred) {
            return postJSON('/auth/passkey/login/verify', assertionToJSON(cred));
        }).then(function (res) {
            if (res && res.ok && res.redirect) { window.location.assign(res.redirect); return; }
            throw new Error('verify failed');
        }).catch(function () { btn.disabled = false; toast('Passkey sign-in did not complete'); });
    }

    function registerPasskey(btn) {
        btn.disabled = true;
        postJSON('/auth/passkey/register/options').then(function (opts) {
            opts.challenge = b64uToBuf(opts.challenge);
            opts.user.id = b64uToBuf(opts.user.id);
            (opts.excludeCredentials || []).forEach(function (c) { c.id = b64uToBuf(c.id); });
            return navigator.credentials.create({ publicKey: opts });
        }).then(function (cred) {
            return postJSON('/auth/passkey/register/verify', attestationToJSON(cred));
        }).then(function (res) {
            if (!res || !res.ok) throw new Error('register failed');
            var done = btn.getAttribute('data-done');
            if (done) window.location.assign(done); else window.location.reload();
        }).catch(function () { btn.disabled = false; toast('Could not add the passkey'); });
    }

    document.querySelectorAll('[data-passkey-login]').forEach(function (btn) {
        btn.addEventListener('click', function (e) { e.preventDefault(); signInWithPasskey(btn); });
    });
    document.querySelectorAll('[data-passkey-register]').forEach(function (btn) {
        btn.addEventListener('click', function (e) { e.preventDefault(); registerPasskey(btn); });
    });
}());
