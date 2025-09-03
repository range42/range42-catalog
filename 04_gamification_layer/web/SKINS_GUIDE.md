# Gamification Skins Guide

This guide explains how to create new, visually distinct gamification skins across HTML, PHP, and Vue frameworks. The key requirement is skin independence: every skin must be fully self-contained and not rely on shared base CSS.

## Principles

- **Self-contained CSS**: No `<link>` to `web/shared/css/design-system.css`. Each skin defines its own base layout, utilities, and components in its own `skin.css`.
- **Token imports allowed**: You may import a skin-specific token file (e.g., `tokens.hospital.css`, `tokens.classic.css`) to centralize variables. If you need full isolation, copy tokens into the skin folder and import locally.
- **Distinct visual identity**: Each skin must look different (colors, shadows, radii, typography, patterns, density).
- **No build step required**: Keep assets static and framework-native.

## Directory structure

- HTML skins: `04_gamification_layer/web/frameworks/html/skins/<skin>/`
- PHP skins: `04_gamification_layer/web/frameworks/php/public/skins/<skin>/`
- Vue skins: `04_gamification_layer/web/frameworks/vue/public/skins/<skin>/`
- Shared tokens: `04_gamification_layer/web/shared/css/tokens.*.css`

Example (Hospital):
- `web/frameworks/html/skins/hospital/index.html`
- `web/frameworks/html/skins/hospital/skin.css`
- `web/frameworks/php/public/skins/hospital/index.php`
- `web/frameworks/php/public/skins/hospital/skin.css`
- `web/frameworks/vue/public/skins/hospital/index.html`
- `web/frameworks/vue/public/skins/hospital/skin.css`

## Minimum files per skin

- **HTML**: `index.html`, `skin.css`
- **PHP**: `index.php`, `skin.css`
- **Vue (public)**: `index.html`, `skin.css`

Each `index.*` should reference only its **local** `skin.css` and not the shared design system.

## Required CSS in each skin

Embed these base layers directly in `skin.css`:

- **Resets & base**
  - `* { box-sizing: border-box; }` (optional if desired)
  - `body { margin: 0; color: var(--text); font-family: ...; background: var(--bg) ... }`
- **Layout & containers**
  - `.container { max-width: 960–1120px; margin: 0 auto; padding: 24px; }`
  - `.header { display:flex; align-items:center; justify-content:space-between; gap:16px; padding:16px 0; }`
  - `.nav { display:flex; gap:12px; flex-wrap:wrap; }`
  - `.panel { background: var(--panel); border: 1px solid …; border-radius: …; padding: 16px; box-shadow: … }`
  - `.footer { opacity:.7; font-size:14px; padding:24px 0; }`
- **Utilities**
  - `.row { display:flex; gap:12px; align-items:center; }`
  - `.space { flex:1 1 auto; }`
  - `.controls { display:flex; gap:8px; align-items:center; }`
- **Components**
  - Buttons: `.btn`, `.btn.primary`, `.btn.ghost`
  - Alerts: `.alert`, `.alert.info`, `.alert.danger`
  - Tables: `.table`, `.table th`, `.table td`
  - Badges: `.badge`, optional variants

Extend with skin-specific motifs (gradients, patterns, borders, radii, typography).

## Content structure recommendations

Design pages to feel real and helpful. Suggested sections:

- Hero with headline, lead text, CTAs, and supporting image
- Quick Links (e.g., appointments, billing, records)
- Key Services / Departments grid
- Provider or Team spotlight
- Resources and Announcements (two-column layout)
- KPIs/Stats (At a glance)
- Testimonials / Stories
- Location/Map and contact info
- Footer actions (create account, contact)

See `html/skins/hospital/index.html` for a comprehensive example.

## Creating a new skin (step-by-step)

1. **Copy a baseline**
   - Duplicate an existing skin folder closest to your theme from each framework you target (HTML/PHP/Vue).
   - Example: copy `web/frameworks/html/skins/hospital` to `web/frameworks/html/skins/<new-skin>`.
2. **Rename and update references**
   - Update titles/brand labels inside `index.*`.
   - Change imagery (e.g., Unsplash links) and copy.
3. **Tokens**
   - Start from an existing tokens file (`web/shared/css/tokens.*.css`).
   - Either keep importing the shared token file, or duplicate it into your skin folder for total isolation.
4. **Distinct motif**
   - Adjust `:root` theme polish (shadows, radii, outlines).
   - Change header background, link hover, panel borders, hero graphics.
5. **Embed base styles**
   - Ensure all base layout/utilities/components are present in `skin.css`.
   - Remove any `<link>` to `shared/css/design-system.css` if present.
6. **Fill sections**
   - Include realistic content: services, providers, announcements, KPIs, testimonials.
   - Add responsive grids as needed with `@media` rules.
7. **Accessibility**
   - Use descriptive `alt` attributes and clear button labels.
   - Ensure focus styles on `button`, `a`, and form controls.
8. **Responsive checks**
   - Test at ~1200px, 900px, 560px. Adjust grid templates and typography.
9. **QA checklist**
   - Page renders with no layout shift.
   - No 404s on local assets.
   - No dependency on `shared/css/design-system.css`.
   - Visual identity clearly distinct from other skins.

## Framework notes

- **HTML**
  - Simple static file. Open `index.html` directly in the browser.
- **PHP**
  - Use `php -S localhost:8080 -t .` from `web/frameworks/php/public/skins/<skin>/` to preview.
  - Keep PHP minimal (layout is static; can echo dynamic time/date if needed).
- **Vue (public)**
  - Static `index.html` in `web/frameworks/vue/public/skins/<skin>/` (no build).
  - If you add Vue components later, keep the skin CSS self-contained.

## Imagery guidelines

- Use relevant Unsplash images for hero/providers/maps.
- Constrain height with `object-fit: cover;` and rounded corners.
- Include descriptive `alt` text.

## Packaging & deployment

- Each skin folder is self-contained and can be zipped and deployed independently.
- If you need to package multiple frameworks for one skin, ship each framework folder separately to keep runtime assumptions simple.

## Do/Don’t

- **Do**: duplicate base layout/utilities into every `skin.css`.
- **Do**: import skin-specific tokens or include them locally.
- **Do**: keep CTAs and key content prominent.
- **Don’t**: reference `shared/css/design-system.css`.
- **Don’t**: rely on global HTML resets outside the skin folder.

## Example scaffolds

HTML header & nav snippet:
```html
<header class="header">
  <div class="brand">
    <div>New Skin</div>
    <div class="badge">Beta</div>
  </div>
  <nav class="nav">
    <a href="#">Dashboard</a>
    <a href="#">Appointments</a>
    <a href="#">Billing</a>
    <a href="#">Support</a>
  </nav>
</header>
```

Common buttons:
```html
<div class="row">
  <button class="btn primary">Primary</button>
  <button class="btn ghost">Secondary</button>
</div>
```

CSS base panel and nav (adapt with your theme):
```css
.header { display:flex; align-items:center; justify-content:space-between; gap:16px; padding:16px 0; }
.nav { display:flex; gap:12px; flex-wrap:wrap; }
.panel { background: var(--panel); border-radius: 10px; padding: 16px; border:1px solid rgba(255,255,255,0.06); }
```

## References in this repo

- Self-contained Hospital skin examples:
  - HTML: `web/frameworks/html/skins/hospital/`
  - PHP: `web/frameworks/php/public/skins/hospital/`
  - Vue: `web/frameworks/vue/public/skins/hospital/`
- Classic skin examples:
  - HTML: `web/frameworks/html/skins/classic/`
  - PHP: `web/frameworks/php/public/skins/classic/`
  - Vue: `web/frameworks/vue/public/skins/classic/`

If you want me to scaffold a new skin (e.g., "Neon", "Serene", or "Tech"), tell me which frameworks to include and I’ll generate the folders and starter files.
