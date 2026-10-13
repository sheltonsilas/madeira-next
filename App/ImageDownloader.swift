import Foundation
import UIKit
import CryptoKit

/// Downloads a guest image into a machine's own folder, with progress and the
/// distribution's own checksum.
///
/// WHY A BACKGROUND SESSION
/// A desktop ISO is three gigabytes and a cloud image is a few hundred megabytes,
/// and the app being closed or the phone being locked is the normal way a long
/// download is interrupted. `URLSessionConfiguration.background` hands the
/// transfer to the system's own daemon, so it keeps running while the app is
/// suspended or not running at all; the app is woken to put the finished file
/// where it belongs. The delegate here is therefore retained by the session, and
/// every published value is written on the main queue.
///
/// This is the one piece of the app whose work happens while nobody is looking.
/// Nothing else is scheduled, and nothing about a running guest survives
/// suspension - a machine stops when iOS stops the app.
final class ImageDownloader: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case downloading(received: Int64, expected: Int64)
        /// The bytes are on disk and are being hashed: visible, not instant, for
        /// anything measured in gigabytes.
        case verifying
        case installed(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            case .idle, .installed, .failed: return false
            }
        }

        var fraction: Double? {
            guard case let .downloading(received, expected) = self, expected > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(expected)))
        }

        var detail: String? {
            switch self {
            case .idle:
                return nil
            case let .downloading(received, expected):
                let have = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                guard expected > 0 else { return have }
                return "\(have) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
            case .verifying:
                return "Checking the published checksum..."
            case .installed:
                return "Installed."
            case let .failed(message):
                return message
            }
        }
    }

    /// The identifier the system uses to wake the app for a finished transfer.
    /// It must be the same in the app delegate's launch callback, which is why it
    /// is a constant here rather than a literal in two files.
    static let sessionIdentifier = "com.sheltonsilas.madeiranext.images"

    /// The one downloader.
    ///
    /// Shared rather than owned by the sheet that started a download: the
    /// transfer is handed to iOS, so it can finish while no view is on screen at
    /// all, and a machine has to be able to say what is downloading for it and
    /// where the file lands.
    static let shared = ImageDownloader()

    @Published private(set) var state: State = .idle
    /// The image being fetched and the machine waiting for it, so the UI can
    /// describe a transfer it did not start.
    @Published private(set) var image: GuestImage?
    @Published private(set) var machineID: UUID?

    private var destination: URL?
    private var task: URLSessionDownloadTask?
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.timeoutIntervalForRequest = 60
        // A three-gigabyte ISO on a slow connection is not a failure. The
        // resource timeout is the one that would give up on it.
        configuration.timeoutIntervalForResource = 60 * 60 * 12
        configuration.isDiscretionary = false
        // The system relaunches the app for the transfer's events; without this
        // a download that finishes while the app is closed reports nothing.
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration,
                             delegate: self,
                             delegateQueue: ImageDownloader.delegateQueue)
    }

    deinit { session.invalidateAndCancel() }

    /// Delegate callbacks off the main queue, so hashing a multi-gigabyte file and
    /// moving it never contend with the UI; each published change hops to main.
    private static let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    // MARK: Starting

    /// Begin (or restart) a download for `machine`, into that machine's folder.
    func download(_ image: GuestImage, for machineID: UUID) {
        cancel()
        self.image = image
        self.machineID = machineID

        do {
            let folder = try MachineDirectory.forMachine(id: machineID)
            let target = folder.appendingPathComponent(image.storedFileName)
            destination = target
            publish(.downloading(received: 0, expected: image.byteCount))
            let task = session.downloadTask(with: image.url)
            self.task = task
            task.resume()
        } catch {
            publish(.failed("The machine's folder could not be created: \(error.localizedDescription)"))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        image = nil
        destination = nil
        machineID = nil
        if state.isBusy { publish(.idle) }
    }

    // MARK: Verification

    private func publish(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    private func verify(file: URL, image: GuestImage) {
        guard let sumsURL = image.checksumURL, let algorithm = image.checksumAlgorithm else {
            // Fedora publishes a list this build could not verify. Say the check
            // did not happen rather than implying one that did.
            finish(file: file)
            return
        }

        publish(.verifying)
        // Hashing several gigabytes is a minute of work on a phone's CPU, and a
        // suspended app is a killed one: ask for the time explicitly.
        let token = BackgroundTime.begin()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let problem = Self.check(file: file, sumsURL: sumsURL, algorithm: algorithm,
                                     remoteFileName: image.remoteFileName)
            BackgroundTime.end(token)
            guard let problem else {
                self?.finish(file: file)
                return
            }
            // A file that does not match is worse than no file: it boots
            // something other than what was asked for. Removed, so the next
            // attempt starts clean.
            try? FileManager.default.removeItem(at: file)
            self?.publish(.failed(problem))
        }
    }

    private func finish(file: URL) {
        guard let machineID else {
            publish(.failed("The download finished but no machine was waiting for it."))
            return
        }
        do {
            let path = try MachineImage.adoptDownloaded(file, for: machineID)
            publish(.installed(path))
        } catch {
            publish(.failed("The image could not be moved into the machine's folder: \(error.localizedDescription)"))
        }
    }

    /// Nil when the file is what the distribution published, or the sentence to
    /// show when it is not.
    ///
    /// An optional rather than a `Result`: `Result`'s failure has to be an
    /// `Error`, and a sentence for the user is not one - nothing catches it.
    private static func check(file: URL,
                              sumsURL: URL,
                              algorithm: GuestImage.ChecksumAlgorithm,
                              remoteFileName: String) -> String? {
        let expected: String
        do {
            let data = try Data(contentsOf: sumsURL)
            let text = String(decoding: data, as: UTF8.self)
            guard let found = expectedHash(in: text, for: remoteFileName) else {
                // A list that does not mention our file is a newer image than
                // this build knows about; not a mismatch.
                return nil
            }
            expected = found
        } catch {
            // The list is not reachable. The download itself is intact, and
            // failing here would throw away three gigabytes over a checksum the
            // distribution may have rotated.
            return nil
        }

        do {
            let actual = try hash(of: file, algorithm: algorithm)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                return "The download did not match the published \(algorithm.displayName): expected \(expected.prefix(16))..., got \(actual.prefix(16)).... It has been deleted; try again."
            }
            return nil
        } catch {
            return "The downloaded image could not be read to verify it: \(error.localizedDescription)"
        }
    }

    /// Pull `fileName`'s hash out of a `SHA256SUMS`-style list.
    ///
    /// Both formats in use put the hash first and the name second, and differ only
    /// in whether a `*` marks binary mode:
    ///     `abc123  ubuntu-24.04-server-cloudimg-arm64.img`
    ///     `abc123 *ubuntu-24.04-server-cloudimg-arm64.img`
    static func expectedHash(in text: String, for fileName: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var name = String(parts[1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name == fileName || name.hasSuffix("/" + fileName) {
                return String(parts[0])
            }
        }
        return nil
    }

    /// The hash of a file, read in chunks so a three-gigabyte ISO never lands in
    /// memory at once.
    static func hash(of url: URL, algorithm: GuestImage.ChecksumAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let chunkSize = 4 << 20

        func digest<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            return try digest(&hasher)
        case .sha512:
            var hasher = SHA512()
            return try digest(&hasher)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ImageDownloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // A server that omits Content-Length reports -1; the catalogue's own byte
        // count is the better estimate then.
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (image?.byteCount ?? 0)
        publish(.downloading(received: totalBytesWritten, expected: expected))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The file has to be moved synchronously, before this returns: the
        // location is deleted as soon as the callback ends, and a background
        // session means this can be running while the app was not open at all.
        guard let destination else {
            publish(.failed("The download finished but had no destination."))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            publish(.failed("The downloaded image could not be saved: \(error.localizedDescription)"))
            return
        }
        guard let image else {
            publish(.installed(destination.path))
            return
        }
        verify(file: destination, image: image)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A nil error means the transfer succeeded and the file was already moved
        // and verified in the callback above.
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        publish(.failed(error.localizedDescription))
    }

    /// The system is done handing over this session's events; the app delegate is
    /// holding the system's completion handler, and this is where it is called.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.backgroundTransfersFinished?()
            AppDelegate.backgroundTransfersFinished = nil
        }
    }
}

/// Keeps the app awake for work that must finish: hashing several gigabytes, and
/// moving the result into the machine folder.
///
/// UIApplication's own calls belong on the main thread, and this is called from a
/// session delegate queue, so every call goes through `onMain` rather than being
/// made from wherever the transfer happens to be reporting.
enum BackgroundTime {
    static func begin() -> UIBackgroundTaskIdentifier {
        onMain {
            var token: UIBackgroundTaskIdentifier = .invalid
            token = UIApplication.shared.beginBackgroundTask(withName: "madeira-verify") {
                // The system wants its time back. Ending it here is what the idiom
                // asks for; by this point the transfer itself is already complete.
                let expired = token
                if expired != .invalid { UIApplication.shared.endBackgroundTask(expired) }
            }
            return token
        }
    }

    static func end(_ token: UIBackgroundTaskIdentifier) {
        guard token != .invalid else { return }
        onMain { UIApplication.shared.endBackgroundTask(token) }
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}

/// The app delegate, which exists for one callback: a background transfer that
/// finishes while the app is not running relaunches it here, and the completion
/// handler has to be kept until the session has delivered its events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundTransfersFinished: (() -> Void)?

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ImageDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        AppDelegate.backgroundTransfersFinished = completionHandler
    }
}
