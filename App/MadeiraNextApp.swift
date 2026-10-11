import SwiftUI

@main
struct MadeiraNextApp: App {
    var body: some Scene {
        WindowGroup {
            MachineListView()
        }
    }
}

/// One Linux machine the user has configured. The launch path is not wired yet:
/// see docs/ARCHITECTURE.md, "Components this project writes".
struct Machine: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var memoryMB: Int
    var cpuCount: Int
}

struct MachineListView: View {
    @State private var machines: [Machine] = [
        Machine(name: "Ubuntu (example)", memoryMB: 2048, cpuCount: 2)
    ]

    var body: some View {
        NavigationStack {
            List(machines) { machine in
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.name).font(.headline)
                    Text("\(machine.memoryMB) MB RAM, \(machine.cpuCount) CPUs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Machines")
        }
    }
}
