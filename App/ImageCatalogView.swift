import SwiftUI

/// The images a machine can be given without leaving the app, and the notes for
/// the guest that has none to download.
struct ImageCatalogView: View {
    let machine: Machine
    let onInstall: (MachineImage.Imported) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloads = ImageDownloader.shared

    var body: some View {
        NavigationStack {
            List {
                if machine.guest == .windows {
                    windowsSection
                } else {
                    ForEach(GuestImageCatalog.all) { distribution in
                        Section {
                            Text(distribution.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(distribution.images) { image in
                                row(image)
                            }
                        } header: {
                            Text(distribution.name)
                        }
                    }
                }

                if let detail = downloads.state.detail {
                    Section("This download") {
                        Text(detail)
                        if let fraction = downloads.state.fraction {
                            ProgressView(value: fraction)
                        }
                        if downloads.state.isBusy {
                            Button("Cancel", role: .destructive) { downloads.cancel() }
                        }
                    }
                }

                Section {
                    Text("A download is handed to iOS, so it keeps going while this app is closed or the screen is locked. It lands in the machine's own folder and is checked against the checksum the distribution publishes before it is used.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(machine.guest == .windows ? "Windows image" : "Linux images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: downloads.state) { _, newState in
                guard case .installed(let path) = newState else { return }
                onInstall(MachineImage.Imported(path: path,
                                                format: MachineImage.format(atPath: path, recorded: nil)))
            }
        }
    }

    private var windowsSection: some View {
        Section("Windows ARM64") {
            Text(WindowsImageGuidance.summary)
                .font(.footnote)
            ForEach(Array(WindowsImageGuidance.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Link("Open uupdump.net", destination: WindowsImageGuidance.sourceURL)
        }
    }

    private func row(_ image: GuestImage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: image.kind.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(image.kind.title).font(.subheadline)
                Text("\(image.sizeDescription) - \(image.storedFileName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(image.kind.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if downloads.state.isBusy {
                ProgressView()
            } else {
                Button("Download") {
                    downloads.download(image, for: machine.id)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
