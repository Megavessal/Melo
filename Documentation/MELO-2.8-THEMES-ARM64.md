# Melo 2.8.0 — Apple Silicon and Cosmic Themes

Melo 2.8.0 targets `arm64` only. The Xcode project, release builder, and Developer Update Center fallback build exclude `x86_64`; the release builder also thins and verifies embedded Mach-O files before signing.

`MeloThemeBackdrop` is shared by the menu-bar panel and Settings.

- **Space:** 21 deterministic stars, restrained sparkle, white-and-red rocket.
- **Galaxy:** 28 deterministic stars, restrained pink sparkle, soft nebula glow, white-and-red rocket.
- **Aurora:** dark northern night, slow green/cyan/violet ribbons, restrained stars, mountain silhouettes, white-and-red rocket.
- **Reduce Motion:** pauses sparkle and presents a quiet stationary rocket.

Theme Studio copies a bounded prompt to ChatGPT in the browser, accepts pasted or imported JSON, validates and clamps it as `GeneratedMeloTheme`, previews it inside Melo, and applies it across both interface surfaces. Allowed styles are `stars`, `aurora`, `nebula`, and `gradient`. It cannot import code, images, URLs, file paths, controls, or layout changes.
