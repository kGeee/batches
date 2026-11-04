Optional creative 3D LUTs, as Adobe `.cube` files named to match `FilmLook.lutResource`.

The film looks don't need LUTs: each stock is defined analytically in `FilmLook.swift`
(balance, crosstalk matrix, per-layer curves, halation, grain). A LUT is an extra, for color
moves the analytic stages can't express.

- Input: scene-linear Rec.2020 after the stock's crosstalk matrix, log encoded with
  `ToneCurve.encodeLog` (0.18 · 2^-8 … 0.18 · 2^+6 mapped to 0…1). Output: same encoding.
  The film curve runs after the LUT.
- Size: 33³ is plenty.
- Versioning: a shipped LUT is frozen like the rest of the pipeline. Put the version in the
  name (`warm160.v1.cube`) and point a new pipeline version at `warm160.v2.cube` instead of
  editing the old file.
- A missing file is skipped, so the look falls back to its analytic stages.
