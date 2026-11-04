#!/usr/bin/env python3
"""Fit a Strewn camera profile (3x3 matrix in linear Rec.2020) from a ColorChecker shot.

1. On the phone, shoot an X-Rite ColorChecker Classic (24 patches) in daylight, filling the
   middle of the frame, with Bayer RAW (and again with ProRAW if you want a ProRAW profile).
2. Export ColorPipeline.calibrationTIFF(dng:) for that DNG (linear Rec.2020, no profile, no film).
3. Read the average RGB of each patch (any image tool; avoid the patch edges) into a CSV with
   24 rows of "r,g,b", in the chart's order: dark skin ... black, row by row.
4. Run:  python3 tools/fit_device_matrix.py measured.csv
   It prints the Swift line to paste into DeviceProfile.matrices, keyed by the DNG's
   UniqueCameraModel, lens model and format (see DeviceProfile.key).

Needs numpy and colour-science (pip install numpy colour-science) for the reference values.
"""
import csv
import sys

import numpy as np


def reference_rec2020_linear():
    import colour

    chart = colour.CCS_COLOURCHECKERS["ColorChecker24 - After November 2014"]
    xyY = np.array(list(chart.data.values()))
    XYZ = colour.xyY_to_XYZ(xyY)
    # Chart values are for D50; adapt to D65, the white point of Strewn's working space.
    rgb = colour.XYZ_to_RGB(XYZ, colour.RGB_COLOURSPACES["ITU-R BT.2020"],
                            illuminant=chart.illuminant, chromatic_adaptation_transform="Bradford",
                            apply_cctf_encoding=False)
    return rgb


def fit(measured, reference):
    # White balance on the middle grey patch (index 21, "neutral 5"), then match exposure.
    measured = measured / measured[21] * reference[21]
    # Least squares with each row summing to 1, so greys stay grey: write the last column
    # as 1 - (first two) and solve for the first two columns of each row.
    M = np.zeros((3, 3))
    A = np.stack([measured[:, 0] - measured[:, 2], measured[:, 1] - measured[:, 2]], axis=1)
    for row in range(3):
        b = reference[:, row] - measured[:, 2]
        (a0, a1), *_ = np.linalg.lstsq(A, b, rcond=None)
        M[row] = [a0, a1, 1 - a0 - a1]
    return M, measured


def delta_e(rgb_a, rgb_b):
    import colour

    space = colour.RGB_COLOURSPACES["ITU-R BT.2020"]
    lab = [colour.XYZ_to_Lab(colour.RGB_to_XYZ(x, space, apply_cctf_decoding=False)) for x in (rgb_a, rgb_b)]
    return colour.delta_E(lab[0], lab[1], method="CIE 2000")


def main(path):
    with open(path) as f:
        rows = [list(map(float, r[:3])) for r in csv.reader(f) if r and not r[0].startswith("#")]
    measured = np.array(rows)
    if measured.shape != (24, 3):
        sys.exit(f"Expected 24 rows of r,g,b, got {measured.shape}")
    reference = reference_rec2020_linear()
    M, balanced = fit(measured, reference)
    corrected = balanced @ M.T
    before, after = delta_e(balanced, reference), delta_e(corrected, reference)
    print(f"Mean ΔE2000 before {before.mean():.2f} (max {before.max():.2f}), after {after.mean():.2f} (max {after.max():.2f})")
    values = ", ".join(f"{v:.5f}" for v in M.flatten())
    print(f'"<UniqueCameraModel>|<LensModel>|bayerRAW": [{values}],')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
