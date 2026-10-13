import Foundation

/// Which guest a machine runs.
///
/// The guest decides how the machine's disks reach it, and that is not a detail:
/// Windows ARM64 has no virtio driver built in, so a disk on a virtio controller
/// is invisible to Windows setup, while Linux has virtio and no USB mass-storage
/// driver in its cloud images. One launcher cannot attach the same devices to
/// both and have either work.
enum GuestKind: String, Codable, CaseIterable, Identifiable {
    case linux
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Windows (ARM64)"
        }
    }

    var summary: String {
        switch self {
        case .linux:
            return "Ubuntu, Debian or Fedora. Disks are attached with virtio, which these images have drivers for."
        case .windows:
            return "Windows on ARM. Disks are attached as USB mass storage, which Windows has drivers for. A Windows 11 image has to be assembled from a UUP dump - see the note on the machine."
        }
    }

    var symbol: String {
        switch self {
        case .linux: return "terminal.fill"
        case .windows: return "square.grid.2x2.fill"
        }
    }
}

/// One machine the user has configured.
struct Machine: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var guest: GuestKind
    var memoryMB: Int
    var cpuCount: Int
    /// The medium this machine boots: an ISO, or a disk image. Absolute, inside
    /// the machine's folder.
    var imagePath: String?
    /// How `imagePath` is read: `raw`, `qcow2` or `iso`.
    ///
    /// Stored rather than guessed from the file name, because the two disagree
    /// exactly where it matters: Ubuntu's cloud images are qcow2 in a file called
    /// `.img`, and a qcow2 disk attached as raw does not boot. Nil for machines
    /// saved before this existed, in which case the extension decides.
    var imageFormat: String?
    /// The blank disk an installer writes to, made by "Create install disk".
    var diskPath: String?

    init(id: UUID = UUID(), name: String, guest: GuestKind = .linux, memoryMB: Int,
         cpuCount: Int, imagePath: String? = nil, imageFormat: String? = nil,
         diskPath: String? = nil) {
        self.id = id
        self.name = name
        self.guest = guest
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.imagePath = imagePath
        self.imageFormat = imageFormat
        self.diskPath = diskPath
    }

    /// Every field is decoded by hand so a file written by an older build still
    /// loads: `imagePath` was the first addition, then `guest`, `imageFormat` and
    /// `diskPath`. A machine that fails to decode is a machine the user loses, so
    /// each new field is decoded as optional (or with a default) rather than
    /// required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        guest = try container.decodeIfPresent(GuestKind.self, forKey: .guest) ?? .linux
        memoryMB = try container.decode(Int.self, forKey: .memoryMB)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        imageFormat = try container.decodeIfPresent(String.self, forKey: .imageFormat)
        diskPath = try container.decodeIfPresent(String.self, forKey: .diskPath)
    }
}

enum MachineValidationError: Error, Equatable {
    case emptyName
    case memoryOutOfRange
    case cpuOutOfRange
}

extension Machine {
    /// Limits are deliberately conservative for an iPhone: 512 MB to 8 GB of RAM
    /// and 1 to 8 vCPUs. The engine will refuse anything beyond what the device can
    /// back, but the form should not offer values it can never accept.
    static let memoryRange = 512...8192
    static let cpuRange = 1...8

    /// What Windows needs to be worth starting, for the form's hint and the
    /// launcher's warning. Not a limit: the user's machine, the user's choice.
    static let windowsSuggestedMemoryMB = 4096
    static let windowsSuggestedCPUs = 2

    func validated() throws -> Machine {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MachineValidationError.emptyName }
        guard Machine.memoryRange.contains(memoryMB) else { throw MachineValidationError.memoryOutOfRange }
        guard Machine.cpuRange.contains(cpuCount) else { throw MachineValidationError.cpuOutOfRange }
        var copy = self
        copy.name = trimmed
        return copy
    }
}

/// Persists the machine list as one JSON file. Reads and writes are atomic, so a
/// crash mid-save cannot leave a half-written file that loses every machine.
final class MachineStore {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location: Application Support/MadeiraNext/machines.json.
    static func defaultStore() throws -> MachineStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("MadeiraNext", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MachineStore(fileURL: directory.appendingPathComponent("machines.json"))
    }

    func load() throws -> [Machine] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Machine].self, from: data)
    }

    func save(_ machines: [Machine]) throws {
        let data = try JSONEncoder().encode(machines)
        try data.write(to: fileURL, options: .atomic)
    }
}
