import SwiftUI

@main
struct MadeiraNextApp: App {
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

    private let store: MachineStore? = try? MachineStore.defaultStore()

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Text(loadError).foregroundStyle(.red)
                    }
                }
                ForEach(machines) { machine in
                    Button {
                        editing = machine
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(machine.name).font(.headline)
                            Text("\(machine.memoryMB) MB RAM, \(machine.cpuCount) CPUs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if machines.isEmpty && loadError == nil {
                    ContentUnavailableView("No machines", systemImage: "desktopcomputer",
                                           description: Text("Tap + to add a Linux machine."))
                }
            }
            .navigationTitle("Machines")
            .toolbar {
                Button {
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
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

    private func load() {
        guard let store else {
            loadError = "Could not open the machine list on this device."
            return
        }
        do {
            machines = try store.load()
            loadError = nil
        } catch {
            loadError = "The saved machine list could not be read: \(error.localizedDescription)"
        }
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
    @State private var memoryMB: Int
    @State private var cpuCount: Int
    @State private var problem: String?

    init(title: String, initial: Machine?, onSave: @escaping (Machine) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _memoryMB = State(initialValue: initial?.memoryMB ?? 2048)
        _cpuCount = State(initialValue: initial?.cpuCount ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Ubuntu desktop", text: $name)
                }
                Section("Resources") {
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: Machine.memoryRange, step: 256)
                    Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: Machine.cpuRange)
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
        let candidate = Machine(id: initial?.id ?? UUID(), name: name, memoryMB: memoryMB, cpuCount: cpuCount)
        do {
            onSave(try candidate.validated())
            dismiss()
        } catch MachineValidationError.emptyName {
            problem = "Give the machine a name."
        } catch {
            problem = "Choose a memory and CPU count within the limits."
        }
    }
}
