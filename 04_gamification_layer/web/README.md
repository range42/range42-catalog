# Gamification Web Layer

One UX/design system with switchable skins and i18n, across multiple implementations (HTML, PHP, Vue). No changes required to `03_container_layer`.

## Layout

- `shared/` – helpers used by multiple languages
  - `css/` – `design-system.css` (base) + `tokens.*.css` (skin tokens)
  - `i18n/` – translation JSONs
  - `js/` – `i18n.js` and `skin.js`
  - `skins/manifest.json` – list of available skins
  
- `frameworks/`
  - `html/` – static example with skins under `html/skins/`
  - `php/public/` – PHP example with skins under `php/public/skins/`
  - `vue/public/` – Vue (CDN) example with skins under `vue/public/skins/`

## Skins

Skins are simple token overrides. Add a new skin by:
1. Create `shared/css/tokens.<skin>.css` defining CSS variables.
2. Create per-framework `frameworks/<fw>/(public/)?skins/<skin>/skin.css` that `@import`s the token file.
3. Add entry to `shared/skins/manifest.json`.

## i18n
- Add `shared/i18n/<lang>.json`.
- Static and PHP examples use `shared/js/i18n.js` (data-i18n attributes).
- Vue example fetches JSON directly (see `public/app.js`).

## Choose skin/language
- Both are persisted in `localStorage` and applied at runtime. Defaults: `classic`, `en`.

Note: Rotation (which skin to use for a given challenge) is handled by the container layer. No user action is needed here; pages just need a `<link id="skin-css">` so the skin path can be set.

## Run examples
- HTML: open `frameworks/html/index.html` in a browser.
- PHP: serve `frameworks/php/public/` with any PHP server.
- Vue: open `frameworks/vue/public/index.html` (Vue via CDN, no build step).
