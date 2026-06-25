// Source a colour from the destination's favicon and apply it as the suggested
// colour, unless the user has already chosen one. Server returns
//   { colour: "#rrggbb" }   (favicon-derived)  or
//   { colour: null }        (no salient favicon colour -> leave it to a default)
// Wire it to the destination URL field's `blur` event in your form.
//
// `applyHex(hex)` is yours: paint the preview + the "auto" swatch + the hidden
// colour input. Keep a `userPicked` flag so an explicit swatch click wins.

function suggestColourFromFavicon(opts) {
    if (opts.userPicked()) return;
    var url = (opts.url() || '').trim();
    if (!url) return;
    // Tolerate URLs typed without a scheme (stripe.com -> https://stripe.com).
    if (!/^https?:\/\//i.test(url)) url = 'https://' + url;
    if (!/^https?:\/\/[^/?#\s]+/i.test(url)) return;

    fetch('/api/brand-colour?url=' + encodeURIComponent(url), { credentials: 'same-origin' })
        .then(function (r) { return r.json(); })
        .then(function (j) {
            if (opts.userPicked()) return;          // they picked while we fetched
            if (!j || !j.colour) return;            // no favicon colour -> default applies
            if (j.colour.charAt(0) === '#') opts.applyHex(j.colour);
        })
        .catch(function () { /* silent on network error */ });
}

// Example wiring:
//   var userPicked = false;
//   destInput.addEventListener('blur', function () {
//       suggestColourFromFavicon({
//           url:        function () { return destInput.value; },
//           userPicked: function () { return userPicked; },
//           applyHex:   function (hex) {
//               colourInput.value = hex;
//               autoSwatch.style.background = hex;
//               renderPreview();
//           }
//       });
//   });
//   swatch.addEventListener('click', function () { userPicked = true; /* ... */ });
