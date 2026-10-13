import SwiftUI

/// The status line under the machine list. Tapping it opens the details.
///
/// It exists because the failure this app was reported for - press Start and the
/// app is gone - happens before anything can be read, and two of its three causes
/// are knowable in advance. A line that says which one is coming is worth more
/// than a paragraph after the fact.
struct CapabilityBanner: View {
    let guestMegabytes: Int?

    @State private var probes: JITProbes = .none

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(line)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .task { probes = JITProbes.read() }
    }

    /// The most important thing that is true right now, in one line.
    private var line: String {
        if LinuxBootCheck.engineURL() == nil {
            return "This build has no engine, so no machine can start."
        }
        if LinuxBootCheck.firmware() == nil {
            return "This build has no UEFI firmware, so no machine can boot."
        }
        if let guestMegabytes,
           CapabilityReport.memoryWarning(guestMegabytes: guestMegabytes,
                                          physicalMemory: ProcessInfo.processInfo.physicalMemory) != nil {
            return "Guest RAM is above what an app without the memory entitlement may hold. Tap for details."
        }
        if JITDetector.status(for: probes).isOn == false {
            return "Executable memory is refused, which this engine does not need. Tap for details."
        }
        return "Engine, firmware and memory limits are all in place. Tap for details."
    }

    private var symbol: String {
        if LinuxBootCheck.engineURL() == nil || LinuxBootCheck.firmware() == nil { return "exclamationmark.triangle.fill" }
        if let guestMegabytes,
           CapabilityReport.memoryWarning(guestMegabytes: guestMegabytes,
                                          physicalMemory: ProcessInfo.processInfo.physicalMemory) != nil {
            return "memorychip.fill"
        }
        return JITDetector.status(for: probes).symbol
    }
}

/// What this build can do, measured rather than described, plus what to do about
/// anything that is wrong.
struct DiagnosticsView: View {
    let guestMegabytes: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var probes: JITProbes = .none
    @State private var showingLog = false

    private var rows: [CapabilityRow] {
        CapabilityReport.rows(probes: probes,
                              engine: EngineLocator.status(),
                              firmware: LinuxBootCheck.firmware(),
                              physicalMemory: ProcessInfo.processInfo.physicalMemory,
                              guestMegabytes: guestMegabytes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("This build") {
                    ForEach(rows, id: \.title) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.title)
                                Spacer()
                                Text(row.value)
                                    .foregroundStyle(row.isWarning ? .red : .secondary)
                            }
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("If a machine will not start") {
                    Text("The console screen carries the guest's own output, and QEMU's errors go there too and to Documents/linux-engine.log. The app survives QEMU giving up, so the reason is readable instead of the app disappearing.")
                        .font(.footnote)
                    Button("Show the engine log") { showingLog = true }
                }

                Section("About executable memory") {
                    Text("iOS refuses executable memory to an app that is not being debugged, and this engine does not need it: it interprets guest code. That is why a machine can run without the JIT entitlement, and why a boot is slow. Enabling JIT through a helper such as StikDebug makes a JIT-capable engine possible later, not this one faster today.")
                        .font(.footnote)
                }

                Section("About guest memory") {
                    Text("A guest's RAM is one allocation inside this app. Without com.apple.developer.kernel.increased-memory-limit, iOS applies the ordinary per-app limit and can kill the app as that allocation is made. Signing with App/MadeiraNext.entitlements - tools/sign_ipa.sh does it - is what asks for the larger limit.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { probes = JITProbes.read() }
            .sheet(isPresented: $showingLog) {
                EngineLogView()
            }
        }
    }
}

/// The engine's own log file, which is where QEMU's last words are.
struct EngineLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "The log is empty: no engine has started on this device yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .navigationTitle("linux-engine.log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let url = EngineOutputCapture.logURL
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }
}
