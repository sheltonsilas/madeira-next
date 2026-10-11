import Foundation

/// One Linux machine the user has configured.
///
/// The launch path is not wired yet; see docs/ARCHITECTURE.md.
struct Machine: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var memoryMB: Int
    var cpuCount: Int
    /// The disk image this machine boots. Absolute, inside the machine's folder.
    var imagePath: String?

    init(id: UUID = UUID(), name: String, memoryMB: Int, cpuCount: Int, imagePath: String? = nil) {
        self.id = id
        self.name = name
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.imagePath = imagePath
    }

    /// Decoded without imagePath before it existed, so old files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memoryMB = try container.decode(Int.self, forKey: .memoryMB)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
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
