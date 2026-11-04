import CoreImage
import ImageIO

/// Per-camera color correction, so the same scene gives the same colors on every iPhone.
///
/// CIRAWFilter already converts each DNG with the color matrices Apple wrote into it, which
/// gets most of the way. What's left is how each sensor's own spectral response differs from
/// what a 3×3 matrix can describe. A profile is one more 3×3 matrix in linear Rec.2020, fitted
/// from a ColorChecker shot on that camera module (see tools/fit_device_matrix.py and
/// docs/color-pipeline.md). Cameras without a profile use the identity matrix.
///
/// A capture freezes the matrix it used into its recipe, so adding or refining a profile later
/// never changes photos that were already taken.
enum DeviceProfile {
    /// Key: "<DNG UniqueCameraModel>|<EXIF LensModel>|<bayer or proraw>".
    /// Fill in from calibration shots. Row-major, rows sum to about 1.
    static let matrices: [String: [Float]] = [:]

    static func key(for raw: CIRAWFilter, format: DevelopState.SourceKind) -> String {
        let props = raw.properties
        let dng = props[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let model = dng?[kCGImagePropertyDNGUniqueCameraModel as String] as? String ?? "unknown"
        let lens = exif?[kCGImagePropertyExifLensModel as String] as? String ?? "unknown"
        return "\(model)|\(lens)|\(format.rawValue)"
    }

    static func matrix(for key: String) -> [Float]? { matrices[key] }
}
