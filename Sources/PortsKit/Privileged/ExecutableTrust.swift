// ExecutableTrust.swift - Checks that a file the helper will run as root can't be changed by other users.
//
// Created by John Yancey on 06/12/2024.
// Copyright © 2026 John Yancey. All rights reserved.
//
import Foundation

/// The helper runs `port` as root, so the file, and every folder above it,
/// must belong to root and not be writable by anyone else; otherwise any user
/// could swap in their own program and have it run as root.
public enum ExecutableTrust {
  public enum Failure: LocalizedError, Equatable {
    case notAbsolute(String)
    case missing(String)
    case notExecutable(String)
    case untrusted(path: String, reason: String)

    public var errorDescription: String? {
      switch self {
      case .notAbsolute(let path): "\(path) isn't an absolute path."
      case .missing(let path): "There is no file at \(path)."
      case .notExecutable(let path): "\(path) isn't an executable file."
      case .untrusted(let path, let reason):
        "The helper won't run \(path) as root: \(reason)."
      }
    }
  }

  /// The real location of `path` (symbolic links followed) once it and its
  /// folders pass the checks. Run the returned path, not `path`, so a link
  /// can't change between the check and the run.
  ///
  /// `owners` are the users allowed to own each item (only root by default),
  /// and `root` is the folder the checks start below, which tests change.
  public static func validate(
    _ path: String, requireExecutable: Bool = true, owners: Set<uid_t> = [0],
    below root: String = "/"
  ) throws -> String {
    guard path.hasPrefix("/") else { throw Failure.notAbsolute(path) }
    guard FileManager.default.fileExists(atPath: path) else { throw Failure.missing(path) }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

    var current = resolved
    while true {
      var info = stat()
      guard lstat(current, &info) == 0 else { throw Failure.missing(current) }
      if !owners.contains(info.st_uid) {
        throw Failure.untrusted(path: resolved, reason: "\(current) isn't owned by root")
      }
      if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
        throw Failure.untrusted(path: resolved, reason: "\(current) can be changed by other users")
      }
      if current == resolved, requireExecutable {
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & S_IXUSR != 0 else {
          throw Failure.notExecutable(resolved)
        }
      }
      let parent = (current as NSString).deletingLastPathComponent
      if current == root || parent == current || !current.hasPrefix(root) { break }
      current = parent
    }
    return resolved
  }
}
