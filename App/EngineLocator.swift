import Foundation

/// Whether the Linux engine is present in this build.
enum EngineStatus: Equatable {
    /// The engine framework was found at this path.
    case available(URL)
    /// No engine framework was found. Machines cannot start.
    case missing
}

/// Finds the QEMU engine framework the app would load.
///
/// The engine is expected at `Frameworks/qemu-aarch64-softmmu.framework/`, the
/// same layout Madeira's packaging step produces (see docs/ARCHITECTURE.md). The
/// locator only checks that the binary exists and is readable. It does not load
/// or sign anything; loading is the launcher's job.
enum EngineLocator {
    static let frameworkName = "qemu-aarch64-softmmu"

    /// The binary inside the framework, or nil when it is absent.
    static func binary(in frameworksDirectory: URL) -> URL? {
        let candidate = frameworksDirectory
            .appendingPathComponent("\(frameworkName).framework", isDirectory: true)
            .appendingPathComponent(frameworkName)
        return FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
    }

    /// The status for the running app.
    static func status(for bundle: Bundle = .main) -> EngineStatus {
        guard let frameworks = bundle.privateFrameworksURL else { return .missing }
        if let path = binary(in: frameworks) {
            return .available(path)
        }
        return .missing
    }
}
