import Foundation

enum ShellError: Error, CustomStringConvertible {
    case failed(command: String, status: Int32, stderr: String)
    var description: String {
        switch self {
        case .failed(let command, let status, let stderr):
            return "\(command) failed (\(status)): \(stderr)"
        }
    }
}

/// Shared subprocess runner + hdiutil-attach output parsing, used by
/// every service that shells out to a system tool (hdiutil, newfs_msdos,
/// du, ffmpeg, ...). Centralized so the disk-image and raw-write
/// services don't each reimplement this.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        try runCapturingStderr(tool, args).stdout
    }

    /// Same as `run`, but also returns stderr on success -- needed for
    /// tools like ffmpeg's silencedetect/loudnorm filters, which report
    /// their actual analysis on stderr even on a clean (status 0) run.
    @discardableResult
    static func runCapturingStderr(_ tool: String, _ args: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ShellError.failed(command: "\(tool) \(args.joined(separator: " "))", status: process.terminationStatus, stderr: err)
        }
        return (out, err)
    }

    /// Parses `/dev/diskN` from the first line of `hdiutil attach` output.
    static func devicePath(fromAttachOutput output: String) -> String? {
        guard let firstLine = output.split(separator: "\n").first else { return nil }
        let cols = firstLine.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        return cols.first
    }

    /// Parses the `/Volumes/...` mount point, if any, from `hdiutil attach` output.
    static func mountPath(fromAttachOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            if let last = cols.last, last.hasPrefix("/Volumes/") {
                return last
            }
        }
        return nil
    }
}
