import Foundation

/// Whether MacPorts can fetch a pre-built binary archive for a port instead of compiling it.
public enum BinaryAvailability: Equatable, Sendable {
    case available
    case unavailable
    /// The archive server couldn't be reached.
    case unknown
}

public enum BinaryArchive {
    public static let archiveSite = URL(string: "https://packages.macports.org")!

    /// The archive platform tag for this Mac, such as `darwin_27` and `arm64`.
    public static func currentPlatform() -> (platform: String, arch: String) {
        var info = utsname()
        uname(&info)
        func string<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let major = string(info.release).split(separator: ".").first.map(String.init) ?? "0"
        let machine = string(info.machine)
        return ("darwin_" + major, machine == "arm64" ? "arm64" : "x86_64")
    }

    /// Archive file names (`*.tbz2`) found in an archive-site directory listing.
    public static func parseListing(_ html: String) -> [String] {
        var names: [String] = []
        var rest = html[...]
        while let range = rest.range(of: "href=\"") {
            rest = rest[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let href = String(rest[..<end])
            rest = rest[end...]
            guard href.hasSuffix(".tbz2"), let last = href.split(separator: "/").last else { continue }
            names.append(String(last).removingPercentEncoding ?? String(last))
        }
        return names
    }

    /// True when `listing` has an archive of `name` at this version and revision, built with
    /// exactly `variants`, for `platform`/`arch` (or platform-independent).
    public static func hasArchive(
        in listing: [String], name: String, version: String, revision: Int,
        variants: [String], platform: String, arch: String
    ) -> Bool {
        let base = "\(name)-\(version)_\(revision)" + variants.sorted().map { "+" + $0 }.joined()
        let suffixes = [
            ".\(platform).\(arch).tbz2", ".darwin_any.noarch.tbz2", ".any_any.noarch.tbz2",
            ".darwin_any.\(arch).tbz2",
        ]
        return suffixes.contains { listing.contains(base + $0) }
    }

    /// True when `listing` has any archive of `name` for `platform`/`arch` (or platform-independent),
    /// whatever its version or variants. A cheap hint for lists; the detail view checks exactly.
    public static func hasAnyArchive(in listing: [String], name: String, platform: String, arch: String) -> Bool {
        let suffixes = [
            ".\(platform).\(arch).tbz2", ".darwin_any.noarch.tbz2", ".any_any.noarch.tbz2",
            ".darwin_any.\(arch).tbz2",
        ]
        return listing.contains { file in
            file.hasPrefix(name + "-") && suffixes.contains { file.hasSuffix($0) }
        }
    }

    /// Whether the archive site has any build of `name` for this Mac. Best effort: failures are `.unknown`.
    public static func anyBuildAvailability(name: String) async -> BinaryAvailability {
        guard PortClient.isValidPortName(name) else { return .unknown }
        var request = URLRequest(url: archiveSite.appendingPathComponent(name, isDirectory: true))
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            if http.statusCode == 404 { return .unavailable }
            guard http.statusCode == 200 else { return .unknown }
            let (platform, arch) = currentPlatform()
            return hasAnyArchive(in: parseListing(String(decoding: data, as: UTF8.self)),
                                 name: name, platform: platform, arch: arch) ? .available : .unavailable
        } catch {
            return .unknown
        }
    }

    /// Looks the port up on the archive site. Best effort: any failure is `.unknown`.
    public static func availability(
        name: String, version: String, revision: Int, variants: [String]
    ) async -> BinaryAvailability {
        guard PortClient.isValidPortName(name) else { return .unknown }
        let url = archiveSite.appendingPathComponent(name, isDirectory: true)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unknown }
            if http.statusCode == 404 { return .unavailable }
            guard http.statusCode == 200 else { return .unknown }
            let listing = parseListing(String(decoding: data, as: UTF8.self))
            let (platform, arch) = currentPlatform()
            return hasArchive(in: listing, name: name, version: version, revision: revision,
                              variants: variants, platform: platform, arch: arch)
                ? .available : .unavailable
        } catch {
            return .unknown
        }
    }
}
