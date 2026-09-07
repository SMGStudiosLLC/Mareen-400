# Changelog

## Vesper 800 (2026-09-07)

This release modifies the Marenn 400 source published on 2026-07-18. Under
GPL-3.0 section 5 this notice records that the work was changed, and when.
The Marenn 400 kernels and host path are preserved verbatim inside
`MarennFilter.swift` and remain selectable.

What changed:

- New look, Vesper 800. Same measured print curve as Marenn 400, rebuilt around
  it: exposure and every optical effect now happen in linear light, the color
  work moved to OKLab, and the grain is a film grain model instead of value
  noise. The file keeps its name so projects that reference it by path keep
  building.
- Halation moved in front of the film curve where it belongs physically. It is
  red dominant with two scales, a tight core and a faint aura, and the blur uses
  as many taps as the radius needs, so 12 MP captures no longer show the dot
  lattice the fixed five tap blur produced at that size.
- A perceptual color stage: subtractive saturation (saturated colors get denser
  and darker), a vibrance style chroma curve, chroma gated hue bands for skin,
  foliage, sky and teal, highlight desaturation toward white, and a gamut safe
  desaturation that keeps hue and luminance when a channel would clip. The
  RGB space blue block, which left a seam through violet on hue sweeps, is gone.
- Grain: integer hash lattice noise, unit variance, a midtone peaked amplitude
  with a shadow floor, a small decorrelated chroma component, blue slightly
  coarser, plus a half code value dither so renders without grain cannot band.
- Scene adaptive development: a 256 bin histogram drives exposure with highlight
  protection, a bounded white balance nudge, and continuous flash, night and
  high key modulation. A content derived seed makes previews and exports match;
  a seeded roll variance gives each photo a tiny exposure and warmth jitter.
- Options: `VesperOptions` with stock, seed, grain, an optional seven segment
  databack stamp exposed onto the film as light, an optional warm light leak,
  and a flash hint. `VesperReport` says what the engine measured and decided.
- Safety: the Metal source is split into a prelude, the Marenn 400 kernels and
  the Vesper 800 kernels. The engine compiles Vesper and falls back to Marenn
  400 if a device rejects the new shader, so the app never loses its filter.
- Host details: threadgroup sizes come from the pipeline state, `bake` fills a
  background so alpha inputs are deterministic, `flatten` skips the redraw for
  upright images, the engine is `@unchecked Sendable`, and 1x1 images render.
- `Tools/vesper_cli.swift` replaces `Tools/marenn_cli.swift`. It compiles
  against the engine file instead of duplicating it, applies EXIF orientation,
  and exposes every option plus `--stats`.
- `Tools/ref`: a CPU reference renderer that compiles the real Metal source
  through a small `metal_stdlib` shim, so the look can be rendered, tuned and
  regression tested on any machine. It reproduces the shipped Marenn 400
  example renders within 1.5/255 RMS. It ships with a struct and kernel parity
  checker, a tree-sitter syntax check for the Swift files, and a small lab for
  contact sheets, charts and OKLab statistics.

## Marenn 400 (2026-07-18)

Initial public release of the Relay film look: five Metal compute kernels,
measured against real film scans.
