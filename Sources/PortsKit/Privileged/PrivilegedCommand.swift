// PrivilegedCommand.swift - The commands the privileged helper will run as root, and how they are validated.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// Names and signing identity shared by the app and its privileged helper.
public enum HelperConstants {
  public static let appIdentifier = "io.indegree.MacPortsApp"
  public static let helperIdentifier = "io.indegree.MacPortsApp.helper"
  /// The launchd label, and the name the helper's XPC service is registered under.
  public static let machServiceName = helperIdentifier
  /// The launchd property list inside the app's `Contents/Library/LaunchDaemons`.
  public static let daemonPlistName = "io.indegree.MacPortsApp.helper.plist"
  public static let teamID = "8Z24F9PX5J"
  /// Bumped when the requests or replies change, so an old helper is not used.
  public static let protocolVersion = 1

  /// A code-signing requirement for the other end of the connection: signed
  /// by this team with that identifier. Each side checks the other with it.
  public static func requirement(identifier: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" "
      + "and certificate leaf[subject.OU] = \"\(teamID)\""
  }

  public static var appRequirement: String { requirement(identifier: appIdentifier) }
  public static var helperRequirement: String { requirement(identifier: helperIdentifier) }
}

/// A `port` command to run as root. The helper never receives a shell
/// command: it checks `verb` and `arguments` against the lists below and runs
/// `port` with them directly.
public struct PrivilegedCommand: Codable, Sendable, Equatable {
  public var verb: String
  public var arguments: [String]
  /// Passes `-v` to `port`.
  public var verbose: Bool
  /// The `port` executable to run; the helper only accepts one that only root
  /// can modify.
  public var portPath: String
  public var protocolVersion: Int

  public init(
    verb: String, arguments: [String] = [], verbose: Bool = false, portPath: String,
    protocolVersion: Int = HelperConstants.protocolVersion
  ) {
    self.verb = verb
    self.arguments = arguments
    self.verbose = verbose
    self.portPath = portPath
    self.protocolVersion = protocolVersion
  }

  public enum Invalid: LocalizedError, Equatable {
    case unknownVerb(String)
    case badArguments(verb: String, argument: String)

    public var errorDescription: String? {
      switch self {
      case .unknownVerb(let verb): "The helper doesn't run `port \(verb)`."
      case .badArguments(let verb, let argument):
        "\(argument) isn't allowed as an argument to `port \(verb)`."
      }
    }
  }

  static let maxArguments = 500
  static let maxArgumentLength = 256

  /// The arguments to give `port`, after checking every one; throws for any
  /// verb or argument that isn't on the allowed list.
  public func portArguments() throws -> [String] {
    try validate()
    return ["-N"] + (verbose ? ["-v"] : []) + [verb] + arguments
  }

  /// "sudo port install zlib +universal", as shown in the Activity log and
  /// in the Touch ID prompt.
  public var summary: String { (["sudo port", verb] + arguments).joined(separator: " ") }

  private func validate() throws {
    func reject(_ argument: String) -> Invalid { .badArguments(verb: verb, argument: argument) }
    guard arguments.count <= Self.maxArguments else { throw reject("\(arguments.count) arguments") }
    for argument in arguments where argument.count > Self.maxArgumentLength {
      throw reject(String(argument.prefix(20)) + "…")
    }
    func isName(_ argument: String) -> Bool { PortClient.isValidPortName(argument) }

    switch verb {
    case "install":
      // A port, then its variant flags.
      guard let name = arguments.first, isName(name) else { throw reject(arguments.first ?? "") }
      for flag in arguments.dropFirst() where !PortClient.isValidVariantFlag(flag) {
        throw reject(flag)
      }
    case "upgrade":
      guard !arguments.isEmpty else { throw reject("") }
      for argument in arguments where !isName(argument) { throw reject(argument) }
    case "uninstall":
      // Ports, each optionally followed by the exact version to remove.
      guard !arguments.isEmpty else { throw reject("") }
      var previousWasName = false
      for argument in arguments {
        if argument.hasPrefix("@") {
          guard previousWasName, PortClient.isValidVersionSpec(argument) else {
            throw reject(argument)
          }
          previousWasName = false
        } else {
          guard isName(argument) else { throw reject(argument) }
          previousWasName = true
        }
      }
    case "activate":
      guard arguments.count == 2, isName(arguments[0]), arguments[1].hasPrefix("@"),
        PortClient.isValidVersionSpec(arguments[1])
      else { throw reject(arguments.joined(separator: " ")) }
    case "clean":
      guard arguments.count == 2, arguments[0] == "--all", isName(arguments[1]) else {
        throw reject(arguments.joined(separator: " "))
      }
    case "select":
      guard arguments.count == 3, arguments[0] == "--set", isName(arguments[1]),
        isName(arguments[2])
      else { throw reject(arguments.joined(separator: " ")) }
    case "selfupdate", "sync":
      guard arguments.isEmpty else { throw reject(arguments.joined(separator: " ")) }
    default:
      throw Invalid.unknownVerb(verb)
    }
  }
}

/// A new `sources.conf` for the helper to put in place of the current one.
public struct SourcesUpdate: Codable, Sendable, Equatable {
  public var contents: String
  public var portPath: String
  public var protocolVersion: Int

  public init(
    contents: String, portPath: String, protocolVersion: Int = HelperConstants.protocolVersion
  ) {
    self.contents = contents
    self.portPath = portPath
    self.protocolVersion = protocolVersion
  }

  static let maxSize = 64 * 1024

  /// Why the helper wouldn't write `contents`, or nil if it would.
  public var problem: String? {
    guard contents.utf8.count <= Self.maxSize else { return "sources.conf is too large." }
    guard !contents.contains("\0") else { return "sources.conf contains a null character." }
    let sources = MacPortsInfo.parseSources(contents)
    guard !sources.isEmpty else { return "sources.conf must list at least one source." }
    for source in sources where !MacPortsInfo.isValidSourceURL(source) {
      return "\(source) isn't an allowed ports source."
    }
    return nil
  }
}

/// How a privileged request ended.
public struct PrivilegedResult: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable {
    /// `port` ran; `status` is its exit status.
    case finished
    /// The request was cancelled and `port` stopped.
    case cancelled
    /// The helper refused the request, or couldn't start `port`; nothing ran.
    case rejected
    /// The helper speaks another protocol version.
    case versionMismatch
  }

  public var kind: Kind
  public var status: Int32
  public var message: String

  public init(kind: Kind, status: Int32 = 0, message: String = "") {
    self.kind = kind
    self.status = status
    self.message = message
  }
}
