import Foundation
import LightsCore

enum RemoteError: Error, LocalizedError {
    case invalidAlias
    case ssh(String)
    case noClaude
    case noPort

    var errorDescription: String? {
        switch self {
        case .invalidAlias: return "Use the name you type after `ssh`, like devbox or me@example.com."
        case .ssh(let why): return "ssh failed: \(why)"
        case .noClaude:     return "Claude Code isn't installed on that machine."
        case .noPort:       return "Couldn't pick a port on that machine."
        }
    }
}

enum TunnelStatus: Equatable {
    case connecting
    case connected
    case failed(String)
}

/// SSH machines added in Setup, and the background tunnels that carry their hooks home.
@MainActor
final class RemoteMachines: ObservableObject {
    static let shared = RemoteMachines()
    private static let defaultsKey = "remoteHosts"
    private static let pidsKey = "tunnelPids"

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var status: [String: TunnelStatus] = [:]

    private var tunnels: [String: Process] = [:]
    private var retryDelay: [String: TimeInterval] = [:]
    private let queue = DispatchQueue(label: "lights.remote")

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            hosts = saved
        }
    }

    // MARK: - Setup

    /// Installs the hook on the machine, adds the tab line to the shell startup files,
    /// and starts the tunnel.
    func add(_ alias: String) async throws {
        guard RemoteSetup.isValidAlias(alias) else { throw RemoteError.invalidAlias }
        // Local steps first, so a failure here leaves the remote machine untouched.
        try LocalFiles.installShellSnippet()
        let authLine = LocalFiles.authLine(try LocalFiles.ensureToken())
        let host = try await runOff { try Self.install(on: alias, authLine: authLine) }
        hosts = hosts.filter { $0.alias != alias } + [host]
        save()
        startTunnel(host)
    }

    func remove(_ alias: String) async {
        stopTunnel(alias)
        hosts = hosts.filter { $0.alias != alias }
        status[alias] = nil
        save()
        // Best effort: the machine may be unreachable, and the entry is gone either way.
        _ = try? await runOff { try Self.uninstall(on: alias) }
    }

    private nonisolated static func install(on alias: String, authLine: String) throws -> RemoteHost {
        let setup = ssh(alias, script: RemoteSetup.installScript(authLine: authLine))
        guard setup.succeeded else { throw RemoteError.ssh(firstLine(setup.stderr)) }
        let values = RemoteSetup.parseOutput(setup.stdout)
        guard values["claude"] == "yes" else { throw RemoteError.noClaude }
        guard let port = values["port"].flatMap(Int.init), RemoteSetup.isUsablePort(port) else {
            throw RemoteError.noPort
        }

        let current = ssh(alias, script: RemoteSetup.readSettingsScript)
        guard current.succeeded else { throw RemoteError.ssh(firstLine(current.stderr)) }
        let settings = try JSONHookMerger.parseJSON(Data(current.stdout.utf8), source: "\(alias):~/.claude/settings.json")
        let updated = JSONHookMerger.installing(JSONHookMerger.claudeHookSpecs, into: settings)
        if try JSONHookMerger.serialize(updated) != JSONHookMerger.serialize(settings) {
            let write = ssh(alias, script: RemoteSetup.writeSettingsScript,
                            input: try JSONHookMerger.serialize(updated))
            guard write.succeeded else { throw RemoteError.ssh(firstLine(write.stderr)) }
        }
        return RemoteHost(alias: alias, port: port)
    }

    private nonisolated static func uninstall(on alias: String) throws {
        let current = ssh(alias, script: RemoteSetup.readSettingsScript)
        guard current.succeeded else { throw RemoteError.ssh(firstLine(current.stderr)) }
        let settings = try JSONHookMerger.parseJSON(Data(current.stdout.utf8), source: alias)
        let updated = JSONHookMerger.uninstalling(from: settings)
        if try JSONHookMerger.serialize(updated) != JSONHookMerger.serialize(settings) {
            _ = ssh(alias, script: RemoteSetup.writeSettingsScript,
                    input: try JSONHookMerger.serialize(updated))
        }
        _ = ssh(alias, script: RemoteSetup.uninstallScript)
    }

    /// Runs `script` with `sh` on the machine. With `input`, the script reads it from stdin.
    private nonisolated static func ssh(_ alias: String, script: String, input: Data? = nil) -> ShellResult {
        guard let input else {
            return Shell.run("/usr/bin/ssh", RemoteSetup.sshOptions + [alias, "sh", "-s"],
                             input: Data(script.utf8), timeout: 30)
        }
        // stdin carries the data, so the script travels as one quoted argument.
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return Shell.run("/usr/bin/ssh", RemoteSetup.sshOptions + [alias, "sh", "-c", quoted],
                         input: input, timeout: 30)
    }

    private nonisolated static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "no response" : line
    }

    private func runOff<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Tunnels

    func startAll() {
        let leftover = UserDefaults.standard.array(forKey: Self.pidsKey) as? [Int32] ?? []
        queue.async { [weak self] in
            Self.kill(leftover)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hosts.forEach(self.startTunnel)
                self.refreshInstalls()
            }
        }
    }

    /// Re-runs the install on each machine so its hook script matches this build.
    /// Unreachable machines are skipped; their tunnels keep retrying on their own.
    private func refreshInstalls() {
        guard let token = try? LocalFiles.ensureToken() else { return }
        let authLine = LocalFiles.authLine(token)
        for host in hosts {
            queue.async { [weak self] in
                guard let fresh = try? Self.install(on: host.alias, authLine: authLine) else { return }
                DispatchQueue.main.async { self?.portChanged(host, to: fresh) }
            }
        }
    }

    /// The machine picked a new port (its ~/.lights/port was deleted): follow it.
    private func portChanged(_ host: RemoteHost, to fresh: RemoteHost) {
        guard fresh.port != host.port, hosts.contains(host) else { return }
        hosts = hosts.map { $0 == host ? fresh : $0 }
        save()
        startTunnel(fresh)
    }

    func stopAll() {
        tunnels.keys.forEach(stopTunnel)
    }

    private func startTunnel(_ host: RemoteHost) {
        stopTunnel(host.alias)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = RemoteSetup.tunnelArguments(for: host)
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        task.standardError = err
        task.terminationHandler = { [weak self] proc in
            let why = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
            DispatchQueue.main.async { self?.tunnelExited(host, process: proc, why: why) }
        }
        status[host.alias] = .connecting
        do {
            try task.run()
        } catch {
            status[host.alias] = .failed(error.localizedDescription)
            scheduleRetry(host)
            return
        }
        tunnels[host.alias] = task
        savePids()
        // ssh -N prints nothing on success; still running after a few seconds means up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.tunnels[host.alias] === task, task.isRunning else { return }
            self.status[host.alias] = .connected
            self.retryDelay[host.alias] = nil
        }
    }

    private func stopTunnel(_ alias: String) {
        guard let task = tunnels.removeValue(forKey: alias) else { return }
        task.terminationHandler = nil
        if task.isRunning { task.terminate() }
        savePids()
    }

    private func tunnelExited(_ host: RemoteHost, process: Process, why: String) {
        guard tunnels[host.alias] === process else { return }
        tunnels[host.alias] = nil
        savePids()
        let line = Self.firstLine(why)
        status[host.alias] = .failed(line == "no response" ? "disconnected" : line)
        scheduleRetry(host)
    }

    private func scheduleRetry(_ host: RemoteHost) {
        // Back off from 5s to 1 min while the machine is unreachable (sleep, no network).
        let delay = min((retryDelay[host.alias] ?? 2.5) * 2, 60)
        retryDelay[host.alias] = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.hosts.contains(host), self.tunnels[host.alias] == nil else { return }
            self.startTunnel(host)
        }
    }

    private func savePids() {
        UserDefaults.standard.set(tunnels.values.map(\.processIdentifier), forKey: Self.pidsKey)
    }

    /// A crash or force quit can leave our tunnels running and holding the remote ports.
    /// Only pids this app started are touched, and only if they still look like our tunnel.
    private nonisolated static func kill(_ pids: [Int32]) {
        for pid in pids {
            let result = Shell.run("/bin/ps", ["-o", "args=", "-p", String(pid)], timeout: 5)
            guard result.succeeded, RemoteSetup.isTunnelCommand(result.stdout) else { continue }
            Darwin.kill(pid, SIGTERM)
        }
    }
}
