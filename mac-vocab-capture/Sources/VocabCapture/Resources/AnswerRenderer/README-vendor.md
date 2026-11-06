# Offline answer-rendering assets

These browser distributions are checked into `vendor/` so screenshot answers render without a CDN, an npm install, or a network connection. They are runtime resources, not Swift or npm package dependencies. All files were copied byte-for-byte from the official npm registry tarballs; `vendor/manifest.json` records the exact versions, registry tarball URLs, npm SHA-512 integrity values, tarball SHA-256 values, and each copied file's SHA-256 and size.

| Package | Pinned version | Browser resource | Global | License |
| --- | --- | --- | --- | --- |
| marked | 15.0.12 | `vendor/marked.min.js` | `marked` | MIT |
| DOMPurify | 3.4.17 | `vendor/purify.min.js` | `DOMPurify` | Apache-2.0 OR MPL-2.0 |
| KaTeX | 0.19.0 | `vendor/katex/katex.min.js`, `katex.min.css`, `auto-render.min.js`, `fonts/` | `katex`, `renderMathInElement` | MIT |
| Mermaid | 11.17.2 | `vendor/mermaid.min.js` | `mermaid` | MIT |

`marked.min.js` is the upstream `lib/marked.umd.js` distribution under a stable local filename; it has not been re-minified. `katex/auto-render.min.js` is upstream `dist/contrib/auto-render.min.js`. KaTeX's complete 60-file font directory is included so every relative font URL in its unmodified CSS resolves locally. The upstream licenses are in `vendor/licenses/`; bundled third-party notices in the JavaScript distributions are retained.

Marked is pinned to 15.0.12: the 16–18 browser bundles contain regular-expression lookbehind, which cannot be parsed by the Safari 16.0 shipped with macOS 13.0. The selected UMD bundle has no lookbehind or Unicode-set (`v`) regular-expression flags. HTML sanitation is handled by the separately pinned current DOMPurify.

Mermaid is intentionally pinned to the maintained 11.x distribution: Mermaid 12 officially targets Safari 17.4+, while the application supports macOS 13. Its tagged TypeScript configuration targets ES2018 with ES2022 library declarations; the IIFE build disables chunk splitting. This is a static compatibility check, not an actual macOS 13 runtime test. Do not upgrade across that browser baseline without verifying the oldest supported WebKit.

Mermaid uses the full standalone `dist/mermaid.min.js` distribution, not the ESM entry point that loads separate diagram chunks. This artifact installs `globalThis.mermaid` and contains no dynamic `import(...)` calls. Markdown HTML still needs sanitizing, Mermaid must use strict security settings, and the embedding page must restrict external resources and navigation; bundled libraries alone do not establish that security boundary.

## Official documentation checked

- Marked browser entry point and required HTML sanitation: https://marked.js.org/ and https://marked.js.org/using_advanced
- DOMPurify distribution and supported configuration: https://github.com/cure53/DOMPurify
- KaTeX browser loading and local font paths: https://katex.org/docs/browser.html
- KaTeX auto-render extension: https://katex.org/docs/autorender.html
- Mermaid 11.17.2 compiler target: https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.2/tsconfig.json
- Mermaid 11.17.2 standalone build configuration: https://github.com/mermaid-js/mermaid/blob/mermaid%4011.17.2/.esbuild/util.ts
- Mermaid browser initialization and security configuration: https://mermaid.js.org/config/usage

## Updating and verifying

1. Choose explicit package versions; fetch metadata from `https://registry.npmjs.org/<package>/<version>` and its `dist.tarball`.
2. Check the downloaded tarball against the metadata's `dist.integrity` before extracting files.
3. Copy the distribution files listed above plus licenses. Preserve upstream bytes and notices. Do not switch Mermaid to its chunked ESM build without updating the offline-loading design.
4. Regenerate the manifest's package records and all file hashes, then run the answer-renderer tests with network access blocked. Confirm Markdown, Mermaid SVG, display and inline math, local fonts, safe malformed-input fallback, and HTML-injection rejection.

Quick byte-integrity check from this directory:

```sh
python3 - <<'PY'
import hashlib, json, pathlib
root = pathlib.Path('vendor')
manifest = json.loads((root / 'manifest.json').read_text())
for entry in manifest['files']:
    content = (root / entry['path']).read_bytes()
    assert len(content) == entry['bytes'], entry['path']
    assert hashlib.sha256(content).hexdigest() == entry['sha256'], entry['path']
print(f"Verified {len(manifest['files'])} vendored files")
PY
```
