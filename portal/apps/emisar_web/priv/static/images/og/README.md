OG cards (1200×630), referenced as `og:image` / `twitter:image`.

- `emisar-og.webp` is the default card (horizontal logo lockup and "Secure
  production access for your AI agents." on the brand glow/grid). Every page
  that doesn't set its own card uses it. Regenerate it from a 1200×630 HTML
  card (real Inter via the self-hosted woff2) screenshotted with headless
  Chrome at 2× and encoded to webp. Brand source: ../brand/ (emisar-logo.svg).

- `og-security.png`, `og-guides.png`, and `og-pricing.png` are per-section
  cards with a tailored headline. They are wired through the controller:
  bespoke actions set `og_image` inline; generated pages map through
  `@og_images` (security/trust/zero-trust share og-security). They are
  generated with ImageMagick using native text and the system Helvetica face,
  because magick's SVG renderer can't resolve fonts. For example:

      magick -size 1200x630 xc:'#07080a' \
        -fill '#36E6A5' -draw 'rectangle 0,0 1200,6' \
        -font /System/Library/Fonts/Helvetica.ttc \
        -fill '#36E6A5' -pointsize 36 -annotate +80+115 'emisar' \
        -fill '#fafafa' -pointsize 68 -annotate +80+305 'Line one' \
        -fill '#36E6A5' -pointsize 68 -annotate +80+388 'Line two.' \
        -fill '#a1a1aa' -pointsize 27 -annotate +80+560 'Tagline.' \
        og-<section>.png
