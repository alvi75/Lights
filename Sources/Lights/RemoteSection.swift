import SwiftUI
import LightsCore

/// "SSH machines" part of the Setup panel.
struct RemoteSection: View {
    @ObservedObject private var remotes = RemoteMachines.shared
    @State private var alias = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SSH machines")
                .font(.headline)
                .padding(.top, 14)
            Text("Claude Code running over ssh reports back to the tab you ssh'd from. Needs key-based login. Open a new terminal tab after adding the first machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(remotes.hosts, id: \.alias) { host in
                row(host)
            }

            HStack {
                TextField("ssh name, e.g. devbox or me@example.com", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isAdding)
                    .onSubmit(add)
                if isAdding {
                    ProgressView().controlSize(.small)
                }
                Button("Add", action: add)
                    .disabled(isAdding || alias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
    }

    private func row(_ host: RemoteHost) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color(remotes.status[host.alias])).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).font(.body.weight(.medium))
                Text(label(remotes.status[host.alias]))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Remove") {
                Task { await remotes.remove(host.alias) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
    }

    private func add() {
        let name = alias.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isAdding else { return }
        isAdding = true
        error = nil
        Task {
            do {
                try await remotes.add(name)
                alias = ""
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }

    private func color(_ status: TunnelStatus?) -> Color {
        switch status {
        case .connected:        .green
        case .failed:           .red
        case .connecting, nil:  .gray
        }
    }

    private func label(_ status: TunnelStatus?) -> String {
        switch status {
        case .connected:        "Connected"
        case .failed(let why):  "Not connected: \(why)"
        case .connecting, nil:  "Connecting…"
        }
    }
}
