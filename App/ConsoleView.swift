import SwiftUI

/// The running machine's serial output, and the way to stop it.
struct MachineConsoleView: View {
    @ObservedObject var runtime = MachineRuntime.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runtime.console.isEmpty ? "Waiting for output…" : runtime.console)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("console")
                }
                .onChange(of: runtime.console) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("console", anchor: .bottom) }
                }
            }
            .background(Color.black)
            .foregroundStyle(Color.green)
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop") { runtime.stop() }
                        .disabled(!runtime.state.isRunning)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}