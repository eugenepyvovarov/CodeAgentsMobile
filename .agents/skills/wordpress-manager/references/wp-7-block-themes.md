# WordPress 7.0 — Block themes, sections, and core blocks

Guidance for agents maintaining marketing pages (especially **selfhosted-ninja-prod** / CodeAgents Mobile) on WordPress **7.0+**.

**Verified on selfhosted.ninja (2026-06-30):** `wp core version` → **7.0**, active theme **Blocksy 2.1.47** (hybrid / classic with block editor + Site Editor features), **110** registered `core/*` blocks.

## Official references

| Resource | URL |
| --- | --- |
| Core Blocks Reference | https://developer.wordpress.org/block-editor/reference-guides/core-blocks/ |
| WordPress 7.0 Field Guide | https://make.wordpress.org/core/2026/05/14/wordpress-7-0-field-guide/ |
| Gallery block (docs) | https://wordpress.org/documentation/article/gallery-block/ |
| Image block (docs) | https://wordpress.org/documentation/article/image-block/ |
| Template part block | https://wordpress.org/documentation/article/template-part-block/ |
| Themes handbook (FSE / block themes) | https://developer.wordpress.org/themes/block-themes/ |
| Dev blog — WP 7.0 themes notes (Mar 2026) | https://developer.wordpress.org/news/2026/03/whats-new-for-developers-march-2026/ |
| Breadcrumb block filters | https://make.wordpress.org/core/2026/03/04/breadcrumb-block-filters/ |
| Navigation overlays (7.0) | https://make.wordpress.org/core/2026/03/04/customisable-navigation-overlays-in-wordpress-7-0/ |

Prefer these over outdated “Gutenberg plugin only” posts when the site runs Core 7.0.

## Block theme vs classic / hybrid (what we can change)

WordPress **block themes** (FSE) structure layouts as HTML templates made of blocks:

| Layer | CPT / files | Role | Agent notes |
| --- | --- | --- | --- |
| **Templates** | `wp_template` / theme `templates/*.html` | Full page shells (index, page, single, 404, …) | Edit via Site Editor or theme files. Include `core/post-content` where post body renders. |
| **Template parts** | `wp_template_part` / theme `parts/*.html` | Reusable **sections**: header, footer, sidebar, general, **navigation-overlay** (7.0) | Inserter **Theme** category; purple icons. Markup: `<!-- wp:template-part {"slug":"header","tagName":"header"} /-->`. |
| **Patterns** | `wp_block` (synced) + theme patterns | Reusable block arrangements; 7.0 defaults many patterns to **contentOnly** editing | Prefer patterns for repeated CTAs; overrides need `"role": "content"` on attributes for custom blocks. |
| **Global Styles** | `theme.json` + user styles | Colors, typography, spacing, block supports, pseudo-classes (`:hover`, `:focus`, …) in 7.0 | Prefer `theme.json` / Additional CSS over one-off inline CSS when changing sitewide look. |
| **Post / page content** | `post_content` | Blocks **inside** the content area only | **Primary lever for marketing pages** on hybrid themes (Blocksy). Does **not** replace the theme’s page title hero unless you hide it via CSS/theme options. |

**selfhosted.ninja uses Blocksy (hybrid):** page **title / hero** still comes from the theme (`hero-section` / `page-title`), not from `post_content`. Site chrome (header/footer) is theme-controlled. Agents should:

1. Prefer **block markup in `post_content`** for body sections (headings, galleries, embeds, groups, buttons).
2. Use **small scoped CSS** in an `<!-- wp:html -->` style block (e.g. `.post-203 …`) only when the theme hero or layout cannot express the design (logo before title, gallery card chrome).
3. Avoid editing Blocksy theme PHP/templates unless the user explicitly wants theme-level changes.
4. Do **not** assume pure block-theme template edits apply 1:1; still use the same **core block markup** in content.

## Site Editor “sections” (conceptual map)

When users say “sections,” map to the correct WordPress concept:

| User language | WordPress 7.0 concept | Typical blocks |
| --- | --- | --- |
| Header / footer | **Template part** (`core/template-part`) | Site Logo, Site Title, Navigation, Social Icons |
| Mobile menu overlay | **Navigation overlay** template part area + `core/navigation-overlay-close` | Patterns for overlay layouts (shipped in 7.0) |
| Page body / article | **Post Content** (`core/post-content` in templates) | Whatever is in the post/page |
| Product hero in content | Group / Cover / Media & Text / custom HTML | Buttons, Paragraph, Image, Icon |
| Image grid / screenshots | **Gallery** (`core/gallery` → nested `core/image`) | Lightbox + navigation (7.0) |
| FAQ | Details / Accordion / Heading + Paragraph | `core/details`, `core/accordion*` |
| Breadcrumb trail | **Breadcrumbs** (`core/breadcrumbs`) — new in 7.0 | Often in header template part |
| Decorative glyph | **Icon** (`core/icon`) — new in 7.0 | SVG from core icon set / registry |
| Tabbed content | Tabs (`core/tabs` family; see core reference) | Prefer when theme/plugin enables full support |
| Query / blog lists | Query Loop (`core/query` + `core/post-template`) | Archives, related posts |

## WordPress 7.0 — blocks and features agents should know

### New / notable in 7.0

- **`core/breadcrumbs`** — hierarchical trail; filters for trail items and taxonomy preference; good in headers/template parts.
- **`core/icon`** — native SVG icons (`/wp/v2/icons`); initial set from `wordpress/icons` (third-party collections later).
- **`core/navigation-overlay-close`** — close control inside customizable mobile navigation overlays.
- **Gallery lightbox navigation** — lightbox on gallery images supports back/next and arrow keys; images with lightbox off are skipped.
- **Image “Enlarge on click” (lightbox)** — per-image `lightbox: { "enabled": true }` in block JSON attributes.
- **Per-block custom CSS** — instance-level CSS in the editor (still prefer scoped content CSS via WP-CLI for automation).
- **Responsive block visibility** — hide/show blocks by viewport in the editor (toolbar / inspector).
- **Pattern `contentOnly` default** — patterns favor content fields over structural editing; admins can opt out for unsynced patterns via `disableContentOnlyForUnsyncedPatterns`.
- **`theme.json` pseudo-elements** — `:hover`, `:focus`, `:focus-visible`, `:active` on blocks/variations.
- **Dimension supports** — width/height (and presets) on more blocks; text indent on paragraphs.
- **PHP-only blocks** — `autoRegister` support flag for server-registered blocks without JS (plugin/theme authors).
- **Heading UX** — heading level variations / easier transforms (still `core/heading`).

### Prefer for marketing / project pages (content blocks)

Use **serialized block comments** in `post_content` (what the block editor saves). Prefer core blocks over freeform HTML when a block exists.

| Goal | Prefer | Avoid / notes |
| --- | --- | --- |
| Section title | `core/heading` | Raw `<h2>` only inside `core/html` when necessary |
| Body copy | `core/paragraph` | |
| CTAs | `core/buttons` + `core/button` | Multiple ad-hoc `<a class="btn">` unless matching existing design system |
| Screenshots / photo grid | **`core/gallery`** with nested **`core/image`** | Plain `<img>` lists; shortcode galleries |
| Enlarge screenshots | Image **`lightbox.enabled`** (gallery supports nav in 7.0) | Third-party lightbox plugins unless required |
| YouTube / embeds | `core/embed` (provider youtube, etc.) | Raw iframes unless embed fails |
| Icon + label cards | `core/columns` / `core/group` + `core/icon` + heading/paragraph | Emoji-only if Icon block unavailable |
| FAQ | `core/details` or `core/accordion` | Huge HTML definition lists |
| Custom layout chrome | `core/group` + block supports (spacing, colors, border) | Prefer over page-wide theme CSS |
| Escape hatch | `core/html` | Keep minimal; document why |

### Gallery block (screenshots) — recommended markup (WP 7.0)

Gallery is a **container** of **Image** blocks (`has-nested-images`). For product screenshots (tall phone UIs):

- Set **`imageCrop`: false** (omit `is-cropped` class) so UI isn’t cut off.
- Use **`columns`: 3 or 4** depending on screenshot aspect.
- Use **`sizeSlug`: `"large"`** and real attachment IDs.
- Enable **lightbox** on each image for enlarge + in-gallery navigation (7.0).
- Prefer `wp_get_attachment_image_url( $id, 'large' )` URLs with width/height attributes.

Example skeleton:

```html
<!-- wp:gallery {"linkTo":"none","columns":4,"sizeSlug":"large","imageCrop":false} -->
<figure class="wp-block-gallery has-nested-images columns-4">
<!-- wp:image {"id":197,"sizeSlug":"large","linkDestination":"none","lightbox":{"enabled":true}} -->
<figure class="wp-block-image size-large"><img src="…/screenshot_1-473x1024.png" alt="…" class="wp-image-197" width="473" height="1024"/></figure>
<!-- /wp:image -->
<!-- more core/image blocks -->
</figure>
<!-- /wp:gallery -->
```

Import media first (`wp media import`), then build markup from attachment IDs. Do not invent IDs.

### Theme / template blocks (Site Editor / block themes)

These belong in **templates / template parts**, not usually in a marketing page body:

| Block name | Purpose |
| --- | --- |
| `core/template-part` | Include header/footer/section |
| `core/post-title` | Dynamic title in template |
| `core/post-content` | Renders page/post body |
| `core/post-featured-image` | Featured image in template |
| `core/post-excerpt`, `core/post-date`, `core/post-terms`, … | Post meta |
| `core/site-logo`, `core/site-title`, `core/site-tagline` | Site identity |
| `core/navigation` (+ link / submenu / overlay close) | Menus |
| `core/query` + `core/post-template` | Loops |
| `core/breadcrumbs` | Hierarchy trail (7.0) |

On Blocksy hybrid sites, the page title hero is theme-rendered; putting `core/post-title` in `post_content` would **duplicate** the title. To put a **logo before the title**, use scoped CSS on the theme hero (e.g. `.post-{ID} .hero-section .entry-header`) or change theme/template settings—not a second heading in content.

## Core blocks inventory (names only)

Authoritative list evolves with Core; always confirm on the target site:

```bash
wp eval '
$r = WP_Block_Type_Registry::get_instance();
foreach (array_keys($r->get_all_registered()) as $n) {
  if (str_starts_with($n, "core/")) echo $n, "\n";
}
'
```

### Text

`core/paragraph`, `core/heading`, `core/list`, `core/list-item`, `core/quote`, `core/pullquote`, `core/code`, `core/preformatted`, `core/verse`, `core/table`, `core/details`, `core/footnotes`, `core/math`, `core/freeform` (Classic)

### Media

`core/image`, `core/gallery`, `core/audio`, `core/video`, `core/file`, `core/media-text`, `core/cover`, `core/embed`, `core/playlist` (+ track where registered)

### Design / layout

`core/group`, `core/columns`, `core/column`, `core/buttons`, `core/button`, `core/separator`, `core/spacer`, `core/accordion`, `core/accordion-item`, `core/accordion-heading`, `core/accordion-panel`, `core/icon` (7.0)

### Theme / dynamic

`core/template-part`, `core/post-content`, `core/post-title`, `core/post-featured-image`, `core/post-excerpt`, `core/post-date`, `core/post-author` (deprecated path — prefer avatar / author name / biography), `core/post-author-name`, `core/post-author-biography`, `core/avatar`, `core/post-terms`, `core/post-navigation-link`, `core/post-time-to-read`, `core/read-more`, `core/breadcrumbs` (7.0), `core/site-logo`, `core/site-title`, `core/site-tagline`, `core/query`, `core/post-template`, `core/query-title`, `core/query-total`, `core/query-no-results`, `core/query-pagination` (+ next/previous/numbers), `core/terms-query`, `core/term-template`, `core/term-name`, `core/term-count`, `core/term-description`

### Navigation / widgets / comments / patterns

`core/navigation`, `core/navigation-link`, `core/navigation-submenu`, `core/navigation-overlay-close` (7.0), `core/home-link`, `core/page-list`, `core/page-list-item`, `core/loginout`, `core/search`, `core/social-links`, `core/social-link`, `core/archives`, `core/calendar`, `core/categories`, `core/latest-posts`, `core/latest-comments`, `core/rss`, `core/tag-cloud`, `core/comments` (+ title, template, pagination, author name, content, date, edit/reply links), `core/block` (synced pattern instance), `core/pattern`, `core/html`, `core/shortcode`, `core/missing`

**Deprecated — do not use in new content:** `core/comment-author-avatar` → use Avatar; `core/post-author` (old) → Avatar + Author Name + Biography; `core/post-comment` → Comments; `core/text-columns` → Columns.

Full attribute/supports tables: [Core Blocks Reference](https://developer.wordpress.org/block-editor/reference-guides/core-blocks/).

## WP-CLI patterns for block content (this skill)

```bash
# Version + theme
wp core version
wp theme list --status=active

# Read / write page body (serialized blocks)
wp post get <ID> --field=post_content
wp post update <ID> /tmp/content.html   # file must be full post_content

# Media for gallery / logo
wp media import /path/to/file.png --title='…' --alt='…' --porcelain
wp eval 'echo wp_get_attachment_image_url(197, "large");'

# List core blocks on this install
wp eval '… WP_Block_Type_Registry …'   # see inventory section

# Featured image (theme/OG; not the same as gallery)
wp post meta update <ID> _thumbnail_id <attachment_id>
```

Remote/SSH invocation follows [wp-cli-usage.md](wp-cli-usage.md). Prefer **remote `ssh` + `wp`** when local `--ssh` floods PHP deprecation noise.

### Editing rules for agents

1. **Round-trip full `post_content`** — never partial HTML that drops block comments.
2. **Keep valid block delimiters** — `<!-- wp:name {json} -->` … `<!-- /wp:name -->`; self-closing where core uses `/-->`.
3. **Gallery / Image** — always set real `id` and `wp-image-{id}` class so media library linkage and lightbox work.
4. **Prefer core blocks** over `core/html` when possible; use HTML for theme-hero CSS or legacy designed components already on the page (e.g. CodeAgents `cam-*` cards) until migrated.
5. **Do not change templates/template parts** on production hybrid themes unless requested; focus on page **203** content for CodeAgents Mobile.
6. After updates, **curl the public URL** and confirm `wp-block-gallery`, `wp-lightbox-container` (when lightbox on), and expected attachment IDs appear in HTML.

## CodeAgents Mobile page conventions (selfhosted)

| Item | Value |
| --- | --- |
| Page ID | **203** (`/projects/codeagents-mobile/`) |
| Parent / index | **196** (`/projects/`) |
| Content policy | **Core blocks only** — no `core/html` / custom CSS in `post_content` |
| Theme page title | Disabled via Blocksy post meta `blocksy_post_meta_options` → `has_hero_section` = **`disabled`** (avoids duplicate H1) |
| Logo + title | `core/group` (flex, nowrap) + resized `core/image` (id **212**, ~72×72, rounded) then `core/heading` level 1 |
| CTAs | `core/buttons` / `core/button` (App Store primary, TestFlight & GitHub outline) |
| Screenshots | `core/gallery` (4 cols, `imageCrop: false`) + nested `core/image` + **lightbox** |
| Features | Two `core/columns` rows of three bordered `core/column` cards |
| FAQ | `core/details` |
| Videos | `core/embed` (YouTube) |
| Featured image | Logo attachment **212** (or product art) for social/OG |
| Logo media | App Icon marketing PNG → `codeagents-mobile-logo` |

When product info changes (features, links, screenshots, FAQ), update page **203** (and **196** blurb if needed) using blocks described above. Prefer blocks over HTML; keep Blocksy hero **disabled** if the title lives in content with the logo.

## Quick decision tree

```
Need to change page body copy / screenshots / embeds?
  → Edit post_content with core blocks (gallery, heading, paragraph, buttons, embed, …)

Need logo beside theme page title on Blocksy?
  → Scoped CSS on .post-{ID} .hero-section (not a second H1 in content)

Need sitewide header/footer / breadcrumbs?
  → Template part / Site Editor (block themes) or Blocksy options — ask user before changing

Need enlarge-on-click screenshots?
  → core/gallery + lightbox on core/image (WP 7.0 navigates between images)

Unsure if a block exists on this install?
  → wp eval registry list or Core Blocks Reference for this major version
```
