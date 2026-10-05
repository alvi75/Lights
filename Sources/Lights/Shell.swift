import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum Shell {
    /// Runs a program without a shell (arguments are passed as-is). Blocks the calling
    /// thread, so call it off the main thread. Kills the process after `timeout` seconds.
    static func run(_ path: String, _ args: [String], input: Data? = nil,
                    timeout: TimeInterval = 10) -> ShellResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do {
            try task.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let input {
            // Off this thread so the timeout below still applies if the child never reads.
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        // Read before waiting so a full pipe can't stall the child.
        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: readers) { errData = err.fileHandleForReading.readDataToEndOfFile() }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            _ = done.wait(timeout: .now() + 1)
            readers.wait()
            return ShellResult(status: -2, stdout: "", stderr: "timed out after \(Int(timeout))s")
        }
        readers.wait()
        return ShellResult(status: task.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}
