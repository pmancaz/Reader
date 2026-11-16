# Bundled extraction dependencies

- Mozilla Readability **0.6.0**, retrieved from the pinned `0.6.0` tag: https://github.com/mozilla/readability/tree/0.6.0. Apache 2.0. See Readability-LICENSE.txt.
- DOMPurify **3.4.18**, retrieved from the pinned `3.4.18` tag: https://github.com/cure53/DOMPurify/tree/3.4.18. Dual licensed Apache 2.0 / MPL 2.0; distributed here under Apache 2.0. See DOMPurify-LICENSE.txt.

Source pages are parsed in an inert document in an empty, ephemeral WebKit instance with a restrictive CSP. Readability selects article content; DOMPurify applies an explicit HTML/attribute allowlist. Embedded scripts, forms, frames, SVG, event handlers, styles and trackers are not retained. Saved articles contain only locally cached raster images, static text, safe external hyperlinks, and a restrictive CSP. WebKit's disposable process data is not authoritative reading data.
