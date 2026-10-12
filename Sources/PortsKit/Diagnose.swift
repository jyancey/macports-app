// Diagnose.swift - Parses the output of `port diagnose`.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// One issue reported by `port diagnose`.
public struct DiagnosticFinding: Identifiable, Hashable, Sendable {
  public enum Severity: String, Sendable {
    case warning = "Warning"
    case error = "Error"
    case note = "Note"
  }
  public let severity: Severity
  public let message: String
  public var id: String { severity.rawValue + message }
}

public enum DiagnoseParser {
  /// Parses `port diagnose` output.
  /// Lines look like `Warning: found dylibs in ...`;
  /// unprefixed lines continue the previous finding, and progress lines
  /// starting with `--->` are skipped.
  public static func parse(_ output: String) -> [DiagnosticFinding] {
    var findings: [DiagnosticFinding] = []
    for raw in output.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("--->") else { continue }
      if let (severity, rest) = split(line) {
        findings.append(DiagnosticFinding(severity: severity, message: rest))
      } else if let last = findings.popLast() {
        findings.append(
          DiagnosticFinding(severity: last.severity, message: last.message + "\n" + line))
      }
    }
    return findings
  }

  private static func split(_ line: String) -> (DiagnosticFinding.Severity, String)? {
    for severity in [DiagnosticFinding.Severity.warning, .error] {
      let prefix = severity.rawValue + ": "
      if line.hasPrefix(prefix) { return (severity, String(line.dropFirst(prefix.count))) }
    }
    return nil
  }
}
