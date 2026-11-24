/// The one version string of Metal-PT: the app, `mpt`, run.json `appVersion` and the upload manifest's `app`.
/// Must equal the repo's `VERSION` file (the bundle's Info.plist versions): `scripts/make-app.sh` refuses to build
/// when they differ, and `MetalPTVersionTests` checks it in `swift test`.
public enum MetalPTVersion {
    public static let current = "0.2.0"
}
