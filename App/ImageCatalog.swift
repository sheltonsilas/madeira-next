import Foundation

/// One downloadable guest image.
///
/// EVERY URL, BYTE COUNT AND CHECKSUM LIST IN GuestImageCatalog WAS FETCHED
/// BEFORE IT WAS WRITTEN DOWN, and `tools/check_image_catalog.py` re-checks all
/// of them against the servers on every CI run. A catalogue of plausible links
/// that 404 is how a first run becomes a bug report, and the check is what makes
/// that a broken build rather than a broken app.
struct GuestImage: Identifiable, Hashable {
    /// What the image gives you once it boots.
    enum Kind: String, CaseIterable, Identifiable {
        case commandLine
        case desktop
        case installer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .commandLine: return "Command line"
            case .desktop: return "Desktop (GUI)"
            case .installer: return "Installer"
            }
        }

        var summary: String {
            switch self {
            case .commandLine:
                return "A terminal, no windows. The smallest download and the quickest to boot."
            case .desktop:
                return "A full graphical desktop. A large download, and this app has no display yet, so only its serial console is visible."
            case .installer:
                return "An installer: it needs a blank disk to install onto before it is useful."
            }
        }

        var symbol: String {
            switch self {
            case .commandLine: return "terminal"
            case .desktop: return "macwindow"
            case .installer: return "opticaldiscdrive"
            }
        }
    }

    /// How QEMU is told to read the file.
    ///
    /// Not inferred from the file name: Ubuntu's cloud images are qcow2 inside a
    /// file whose name ends in `.img`, and a qcow2 disk handed to QEMU as `raw`
    /// does not boot - it reads the header as partition data. The catalogue says
    /// what each image really is, and `MachineImage.format(of:)` sniffs the
    /// header of anything imported by hand.
    enum DiskFormat: String, Comparable {
        case raw
        case qcow2
        case iso

        static func < (lhs: DiskFormat, rhs: DiskFormat) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum ChecksumAlgorithm: String { case sha256, sha512
        var displayName: String { rawValue.uppercased() }
    }

    let id: String
    let kind: Kind
    /// The name the server publishes, which is the name a published checksum
    /// list uses.
    let remoteFileName: String
    /// The name it is stored under on the device. Its extension is what the disk
    /// is attached as, so a cloud image called `.img` upstream is stored as
    /// `.qcow2` here.
    let storedFileName: String
    let url: URL
    let format: DiskFormat
    let byteCount: Int64
    /// The published checksum list covering `remoteFileName`, when the
    /// distribution publishes one. Fedora's is left out because the URL could not
    /// be verified; an unverifiable checksum is worse than none.
    let checksumURL: URL?
    let checksumAlgorithm: ChecksumAlgorithm?

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// True for an installer: it has nothing to boot into until a disk is made.
    var needsInstallDisk: Bool { kind == .installer }
}

/// A distribution a user can pick, grouped for the picker.
struct GuestDistribution: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let summary: String
    let images: [GuestImage]
}

/// What this build can fetch, and what it cannot.
enum GuestImageCatalog {
    static let all: [GuestDistribution] = [ubuntu, debian, fedora]

    static func distribution(id: String) -> GuestDistribution? {
        all.first { $0.id == id }
    }

    static func image(id: String) -> GuestImage? {
        for distribution in all {
            if let image = distribution.images.first(where: { $0.id == id }) { return image }
        }
        return nil
    }

    /// Every image, flattened.
    static var images: [GuestImage] { all.flatMap(\.images) }

    /// Ubuntu, because it publishes both a command-line cloud image and a
    /// desktop installer on a stable release path, and publishes a SHA-256 list
    /// covering each.
    static let ubuntu = GuestDistribution(
        id: "ubuntu-24.04",
        name: "Ubuntu 24.04 LTS",
        family: "Ubuntu",
        summary: "Long-term support until 2029, and the distribution most guides assume.",
        images: [
            GuestImage(
                id: "ubuntu-24.04-minimal",
                kind: .commandLine,
                remoteFileName: "ubuntu-24.04-minimal-cloudimg-arm64.img",
                storedFileName: "ubuntu-24.04-minimal.qcow2",
                url: URL(string: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img")!,
                format: .qcow2,
                byteCount: 229_048_320,
                checksumURL: URL(string: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
            GuestImage(
                id: "ubuntu-24.04-server",
                kind: .commandLine,
                remoteFileName: "ubuntu-24.04-server-cloudimg-arm64.img",
                storedFileName: "ubuntu-24.04-server.qcow2",
                url: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img")!,
                format: .qcow2,
                byteCount: 620_224_512,
                checksumURL: URL(string: "https://cloud-images.ubuntu.com/releases/noble/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
            GuestImage(
                id: "ubuntu-24.04-live-server",
                kind: .installer,
                remoteFileName: "ubuntu-24.04.3-live-server-arm64.iso",
                storedFileName: "ubuntu-24.04.3-live-server-arm64.iso",
                url: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-live-server-arm64.iso")!,
                format: .iso,
                byteCount: 3_000_496_128,
                checksumURL: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
            GuestImage(
                id: "ubuntu-24.04-desktop",
                kind: .desktop,
                remoteFileName: "ubuntu-24.04.3-desktop-arm64.iso",
                storedFileName: "ubuntu-24.04.3-desktop-arm64.iso",
                url: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-desktop-arm64.iso")!,
                format: .iso,
                byteCount: 3_473_190_912,
                checksumURL: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
        ])

    static let debian = GuestDistribution(
        id: "debian-12",
        name: "Debian 12 (bookworm)",
        family: "Debian",
        summary: "No desktop, very stable, and the smallest general-purpose image here.",
        images: [
            GuestImage(
                id: "debian-12-genericcloud",
                kind: .commandLine,
                remoteFileName: "debian-12-genericcloud-arm64.qcow2",
                storedFileName: "debian-12-genericcloud-arm64.qcow2",
                url: URL(string: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2")!,
                format: .qcow2,
                byteCount: 342_294_528,
                checksumURL: URL(string: "https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"),
                checksumAlgorithm: .sha512),
        ])

    static let fedora = GuestDistribution(
        id: "fedora-41",
        name: "Fedora 41 Cloud",
        family: "Fedora",
        summary: "Recent packages and a recent kernel. Command line only.",
        images: [
            GuestImage(
                id: "fedora-41-cloud",
                kind: .commandLine,
                remoteFileName: "Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2",
                storedFileName: "Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2",
                url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2")!,
                format: .qcow2,
                byteCount: 495_255_552,
                checksumURL: nil,
                checksumAlgorithm: nil),
        ])
}

/// Windows, which cannot be in the catalogue above.
///
/// Windows 11 ARM64 is not published as a downloadable ISO: Microsoft ships it
/// through its own media creation tool and to OEMs, and what a user can get by
/// hand comes from a UUP dump, assembled on a Windows PC. There is therefore no
/// URL to put in the table, and inventing one would be a button that fails.
///
/// What the app can do is say so, and say what a Windows guest needs. Both of
/// these are facts about Windows on ARM and not about this app, so they are
/// written once here and shown wherever a Windows machine is configured.
enum WindowsImageGuidance {
    static let summary = """
    Windows ARM64 has no direct download. The image has to be assembled from a UUP dump on a Windows PC \
    (uupdump.net, choose an arm64 build and the "create ISO" option), or taken from a machine that already \
    has one. Bring it here with the disk-image picker, then start the machine.
    """

    static let steps: [String] = [
        "Assemble a Windows 11 ARM64 ISO from a UUP dump, or copy one you already have. Nothing in this app can build it for you.",
        "Windows 11 setup requires a TPM 2.0 and Secure Boot. This engine provides a pflash UEFI with neither, so setup refuses to continue unless its checks are bypassed - press Shift+F10 at the first setup screen and use the registry keys under HKLM\\SYSTEM\\Setup\\LabConfig that disable TPM, Secure Boot and RAM checks.",
        "Give the machine its own install disk before starting: Windows setup installs to a disk, and an ISO on its own installs nowhere. \"Create install disk\" in the machine's menu makes one.",
        "Give it at least 4096 MB of RAM and 2 CPUs. Windows is not a small guest, and this engine interprets rather than compiles, so a first boot is slow.",
        "Devices are attached as USB mass storage rather than virtio: Windows ARM64 has those drivers built in and does not have virtio's, which is what makes an install possible without a driver disk.",
    ]

    /// Where a user gets one, as a link the app can open.
    static let sourceURL = URL(string: "https://uupdump.net/")!
}
