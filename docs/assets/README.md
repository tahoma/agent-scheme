# Brand assets

`consent-logo.svg` is the source of truth for the Consent Scheme logo: a
yin-yang whose two dots are a brush **λ** (computation) and a single-stroke
**ensō speech bubble** (dialogue / consent). A thin neutral outer ring keeps the
disc legible on both light and dark backgrounds — for example GitHub's two
README themes, where the near-white and near-black halves would otherwise blend
into the page.

`consent-logo.png` is a derived raster for renderers that do not support SVG. It
is regenerated from the SVG, so edit the SVG and re-run the command below rather
than editing the PNG by hand:

```sh
rsvg-convert -w 800 docs/assets/consent-logo.svg -o docs/assets/consent-logo.png
```

The top-level `README.md` embeds the PNG so the logo renders reliably when the
repository is viewed on GitHub.
