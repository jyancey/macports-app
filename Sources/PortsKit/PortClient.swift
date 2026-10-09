import Foundation

public enum PortClientError: LocalizedError {
    case notInstalled(String)
    case commandFailed(status: Int32, stderr: String)
    case unparseable(String)

    public var errorDescription: String? {
        switch self {
        case .unparseable(let name):
            return "Couldn't read information for \(name)."
        case .notInstalled(let path):
            return "MacPorts was not found at \(path). Install it from macports.org."
        case .commandFailed(let status, let stderr):
            return "port exited with status \(status): \(stderr)"
        }
    }
}

/// Thin wrapper around the MacPorts `port` command line tool.
public struct PortClient: Sendable {
    public static let defaultExecutablePath = "/opt/local/bin/port"

    public let executableURL: URL

    public init(executablePath: String = PortClient.defaultExecutablePath) {
        self.executableURL = URL(fileURLWithPath: executablePath)
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func installedPorts() async throws -> [InstalledPort] {
        let output = try await run(["-q", "installed"])
        return PortListParser.parseInstalled(output)
    }

    public func info(for name: String) async throws -> PortInfo {
        let output = try await run(["-q", "info", "--line"] + PortInfoParser.fieldFlags + [name])
        guard let info = PortInfoParser.parse(output) else {
            throw PortClientError.unparseable(name)
        }
        return info
    }

    /// Files installed by the port (empty if the port isn't installed).
    public func contents(of name: String) async throws -> [String] {
        PortInfoParser.parseFileList(try await run(["-q", "contents", name]))
    }

    /// Installed ports that depend on the given port.
    public func dependents(of name: String) async throws -> [String] {
        PortInfoParser.parseDependents(try await run(["-q", "dependents", name]))
    }

    func run(_ arguments: [String]) async throws -> String {
        guard isAvailable else { throw PortClientError.notInstalled(executableURL.path) }
        let url = executableURL
        return try await Task.detached {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            // Drain stderr concurrently so neither pipe buffer can fill and block the process.
            async let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errBytes = await errData
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PortClientError.commandFailed(
                    status: process.terminationStatus,
                    stderr: String(decoding: errBytes, as: UTF8.self))
            }
            return String(decoding: outData, as: UTF8.self)
        }.value
    }
}
