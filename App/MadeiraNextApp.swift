import SwiftUI
import UniformTypeIdentifiers

@main
struct MadeiraNextApp: App {
    /// The delegate exists for one callback: a background image download that
    /// finishes while the app is not running relaunches it there.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            MachineListView()
        }
    }
}

/// The list of machines, loaded from and saved to disk through MachineStore.
struct MachineListView: View {
    @State private var machines: [Machine] = []
    @State private var editing: Machine?
    @State private var isAdding = false
    @State private var loadError: String?
    @State private var showingConsole = false
    @State private var importing: Machine?
    @State private var catalogFor: Machine?
    @State private var showingDiagnostics = false
    @State private var notice: String?
    @ObservedObject private var runtime = MachineRuntime.shared

    private let store: MachineStore? = try? MachineStore.defaultStore()

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red)
                    }
                }
                if let notice {
                    Section {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(machines) { machine in
                    HStack {
                        Button {
                            editing = machine
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label {
                                    Text(machine.name).font(.headline)
                                } icon: {
                                    Image(systemName: machine.guest.symbol)
                                }
                                Text("\(machine.guest.title), \(machine.memoryMB) MB RAM, \(machine.cpuCount) CPUs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(mediumSummary(machine))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if runtime.state.isRunning && runtime.runningMachine == machine.id {
                            Button("Console") { showingConsole = true }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Start") { start(machine) }
                                .buttonStyle(.borderedProminent)
                                .disabled(runtime.state.isRunning)
                        }
                        Menu {
                            Button("Download a \(machine.guest == .windows ? "Windows" : "Linux") image...") {
                                catalogFor = machine
                            }
                            Button("Choose disk image...") { importing = machine }
                            Button("Create install disk (\(MachineImage.installDiskGigabytes) GB)") {
                                createInstallDisk(machine)
                            }
                            if machine.diskPath != nil {
                                Button("Clear install disk", role: .destructive) { clearInstallDisk(machine) }
                            }
                            if machine.imagePath != nil {
                                Button("Clear image", role: .destructive) { clearImage(machine) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .disabled(runtime.state.isRunning)
                    }
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if machines.isEmpty && loadError == nil {
                    ContentUnavailableView("No machines", systemImage: "desktopcomputer",
                                           description: Text("Tap + to add a Linux or Windows machine."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                CapabilityBanner(guestMegabytes: machines.first?.memoryMB)
                    .onTapGesture { showingDiagnostics = true }
            }
            .navigationTitle("Machines")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingDiagnostics = true
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingConsole) {
                MachineConsoleView()
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView(guestMegabytes: machines.first?.memoryMB)
            }
            .sheet(item: $catalogFor) { machine in
                ImageCatalogView(machine: machine) { installed in
                    adopt(installed, for: machine)
                }
            }
            .onChange(of: ImageDownloader.shared.state) { _, newState in
                // A download started from a machine's own sheet, finished after
                // that sheet was closed: the machine it was for is the one that
                // gets the file.
                guard case .installed(let path) = newState,
                      let machineID = ImageDownloader.shared.machineID,
                      let machine = machines.first(where: { $0.id == machineID }) else { return }
                adopt(MachineImage.Imported(path: path,
                                            format: MachineImage.format(atPath: path, recorded: nil)),
                      for: machine)
            }
            .fileImporter(isPresented: Binding(get: { importing != nil },
                                               set: { if !$0 { importing = nil } }),
                          allowedContentTypes: MachineImage.extensions.compactMap { UTType(filenameExtension: $0) },
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .sheet(isPresented: $isAdding) {
                MachineFormView(title: "New machine", initial: nil) { saved in
                    upsert(saved)
                }
            }
            .sheet(item: $editing) { machine in
                MachineFormView(title: "Edit machine", initial: machine) { saved in
                    upsert(saved)
                }
            }
        }
        .task { load() }
    }

    private func mediumSummary(_ machine: Machine) -> String {
        guard let imagePath = machine.imagePath else { return "No image yet" }
        let format = MachineImage.format(atPath: imagePath, recorded: machine.imageFormat)
        let name = URL(fileURLWithPath: imagePath).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: imagePath)[.size] as? NSNumber)?.int64Value ?? 0
        let readable = size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "empty"
        let disk = machine.diskPath == nil ? "" : " + install disk"
        return "\(format): \(name) (\(readable))\(disk)"
    }

    private func start(_ machine: Machine) {
        do {
            try runtime.start(machine)
            showingConsole = true
            loadError = nil
            notice = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func adopt(_ installed: MachineImage.Imported, for machine: Machine) {
        var updated = machine
        updated.imagePath = installed.path
        updated.imageFormat = installed.format
        upsert(updated)
        notice = "\(URL(fileURLWithPath: installed.path).lastPathComponent) is ready. Press Start."
        loadError = nil
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let machine = importing else { return }
        importing = nil
        do {
            guard let url = try result.get().first else {
                loadError = "No disk image was chosen."
                return
            }
            let imported = try MachineImage.importImage(from: url, for: machine.id)
            var updated = machine
            updated.imagePath = imported.path
            updated.imageFormat = imported.format
            upsert(updated)
            notice = "\(URL(fileURLWithPath: imported.path).lastPathComponent) was copied in as \(imported.format)."
            loadError = nil
        } catch {
            loadError = "The disk image could not be imported: \(error.localizedDescription)"
        }
    }

    private func createInstallDisk(_ machine: Machine) {
        do {
            let path = try MachineImage.createInstallDisk(for: machine.id)
            var updated = machine
            updated.diskPath = path
            upsert(updated)
            notice = "A \(MachineImage.installDiskGigabytes) GB install disk is ready for this machine."
            loadError = nil
        } catch {
            loadError = "The install disk could not be created: \(error.localizedDescription)"
        }
    }

    private func clearInstallDisk(_ machine: Machine) {
        var updated = machine
        if let path = machine.diskPath { try? FileManager.default.removeItem(atPath: path) }
        updated.diskPath = nil
        upsert(updated)
    }

    private func clearImage(_ machine: Machine) {
        var updated = machine
        updated.imagePath = nil
        updated.imageFormat = nil
        upsert(updated)
    }

    private func load() {
        guard let store else {
            loadError = "Could not open the machine list on this device."
            return
        }
        do {
            machines = try store.load()
            loadError = nil
            adoptFinishedDownloads()
        } catch {
            loadError = "The saved machine list could not be read: \(error.localizedDescription)"
        }
    }

    /// Give a machine an image that finished downloading while this app was not
    /// running.
    ///
    /// A background transfer is handed to iOS, so it can complete with no view on
    /// screen and no callback left to receive it. The file is in the machine's
    /// folder; this is what notices, so "the download finished hours ago" does not
    /// mean "now find it in the picker".
    private func adoptFinishedDownloads() {
        var changed = false
        for index in machines.indices where machines[index].imagePath == nil {
            guard let folder = try? MachineDirectory.forMachine(id: machines[index].id),
                  let found = MachineImage.catalogImage(in: folder) else { continue }
            machines[index].imagePath = found.path
            machines[index].imageFormat = found.format
            changed = true
        }
        if changed { persist() }
    }

    private func upsert(_ machine: Machine) {
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
        persist()
    }

    private func delete(at offsets: IndexSet) {
        machines.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        do {
            try store?.save(machines)
            loadError = nil
        } catch {
            loadError = "The machine list could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Add or edit one machine. Validation runs through Machine.validated(), so the
/// rules live in one place and the form only displays their messages.
struct MachineFormView: View {
    let title: String
    let initial: Machine?
    let onSave: (Machine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var guest: GuestKind
    @State private var memoryMB: Int
    @State private var cpuCount: Int
    @State private var problem: String?

    init(title: String, initial: Machine?, onSave: @escaping (Machine) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _guest = State(initialValue: initial?.guest ?? .linux)
        _memoryMB = State(initialValue: initial?.memoryMB ?? 2048)
        _cpuCount = State(initialValue: initial?.cpuCount ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Ubuntu desktop", text: $name)
                }
                Section("Guest") {
                    Picker("Guest", selection: $guest) {
                        ForEach(GuestKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text(guest.summary).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Resources") {
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: Machine.memoryRange, step: 256)
                    Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: Machine.cpuRange)
                    if guest == .windows && (memoryMB < Machine.windowsSuggestedMemoryMB || cpuCount < Machine.windowsSuggestedCPUs) {
                        Text("Windows wants at least \(Machine.windowsSuggestedMemoryMB) MB and \(Machine.windowsSuggestedCPUs) CPUs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let candidate = Machine(id: initial?.id ?? UUID(), name: name, guest: guest,
                                memoryMB: memoryMB, cpuCount: cpuCount)
        do {
            var validated = try candidate.validated()
            // The media belong to the machine being edited, not to the form: a
            // saved machine that forgot its disk image is a machine that will not
            // boot.
            validated.imagePath = initial?.imagePath
            validated.imageFormat = initial?.imageFormat
            validated.diskPath = initial?.diskPath
            onSave(validated)
            dismiss()
        } catch MachineValidationError.emptyName {
            problem = "Give the machine a name."
        } catch {
            problem = "Choose a memory and CPU count within the limits."
        }
    }
}
