// UpdateChecker: tells you when a newer WalkScape is out. This is the app's one connection to the
// internet: a GET of the latest release from GitHub's API (no account, no cookies, no identifiers),
// at launch and then once a day while the app runs, unless WalkScape → Check for Updates
// Automatically is turned off. A newer release shows Update Available next to the version at the
// top of the settings panel, which opens the release's page in the browser. The app downloads and installs nothing itself.
//
// Versions are MAJOR.MINOR.PATCH (bundle/Info.plist), and releases are tagged v<version>. The
// old tags, v0.1-<build>, compare as 0.1.
// WALKSCAPE_LATEST_RELEASE=v9.9.9 pretends that's the latest release, without going online (for
// checking the UI, also in snapshot mode).

import AppKit
import Foundation
import Observation
import os

@MainActor @Observable
final class UpdateChecker {
  /// Where releases are published.
  nonisolated static let repository = "beshanoe/walkscape"
  nonisolated static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
  nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

  /// This copy's version, "0.2.0".
  let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

  /// The newer release's version ("0.3.0"); nil when this copy is the latest or nothing is known yet.
  private(set) var available: String?
  private(set) var checking = false
  /// The answer to Check for Updates…, shown as an alert.
  var report: Report?
  struct Report {
    let title: String
    let message: String
    let newer: Bool
  }

  /// Saved as "checkForUpdates"; on unless turned off.
  var automatic: Bool {
    didSet {
      guard automatic != oldValue else { return }
      UserDefaults.standard.set(automatic, forKey: "checkForUpdates")
      if automatic {
        if started { startChecking() }
      } else {
        loop?.cancel()
        loop = nil
      }
    }
  }

  private var started = false
  private var loop: Task<Void, Never>?
  private let log = Logger(subsystem: "dev.walkscape.app", category: "updates")
  nonisolated private static let fakeLatest: String? = {
    let tag = ProcessInfo.processInfo.environment["WALKSCAPE_LATEST_RELEASE"] ?? ""
    return tag.isEmpty ? nil : tag
  }()

  init() {
    automatic = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true
    if let fake = Self.fakeLatest, Self.isNewer(fake, than: currentVersion) { available = Self.displayVersion(fake) }
  }

  /// Checks now and then once a day, while automatic checks are on.
  func start() {
    started = true
    if automatic { startChecking() }
  }

  /// Check for Updates…: checks now and reports the answer, even with automatic checks off.
  func checkNow() {
    Task { await check(manual: true) }
  }

  func openReleasePage() {
    NSWorkspace.shared.open(Self.releasesPage)
  }

  private func startChecking() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check(manual: false)
        // A continuous clock: after the Mac has slept through a day, the next check comes on waking.
        try? await Task.sleep(for: .seconds(24 * 60 * 60))
      }
    }
  }

  private func check(manual: Bool) async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    do {
      let tag: String?
      if let fake = Self.fakeLatest { tag = fake } else { tag = try await Self.fetchLatestTag() }
      let newer = tag.map { Self.isNewer($0, than: currentVersion) } ?? false
      available = newer ? tag.map(Self.displayVersion) : nil
      log.notice("latest release \(tag ?? "none", privacy: .public); this is \(self.currentVersion, privacy: .public): \(newer ? "update available" : "up to date", privacy: .public)")
      guard manual else { return }
      if let available {
        report = Report(title: "WalkScape \(available) is available",
                        message: "You have version \(currentVersion). The release page has what's new and the download.",
                        newer: true)
      } else if let tag, Self.isNewer(currentVersion, than: tag) {
        report = Report(title: "WalkScape is up to date",
                        message: "Version \(currentVersion) is newer than the latest release, \(Self.displayVersion(tag)).",
                        newer: false)
      } else {
        report = Report(title: "WalkScape is up to date", message: "Version \(currentVersion) is the latest.", newer: false)
      }
    } catch {
      log.error("update check failed: \(error.localizedDescription, privacy: .public)")
      if manual {
        report = Report(title: "Couldn't check for updates", message: error.localizedDescription, newer: false)
      }
    }
  }

  /// The latest release's tag from GitHub ("v0.3.0"), nil if there's no release yet. Sends the
  /// request and nothing else: an ephemeral session (no cookies, no cache on disk), a plain
  /// User-Agent (GitHub requires one) and no language preference.
  nonisolated static func fetchLatestTag(from url: URL = latestReleaseAPI) async throws -> String? {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("WalkScape", forHTTPHeaderField: "User-Agent")
    request.setValue("en", forHTTPHeaderField: "Accept-Language")
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return nil }
    guard status == 200 else { throw CheckError(errorDescription: "GitHub answered with status \(status).") }
    struct Release: Decodable { let tag_name: String }
    return try JSONDecoder().decode(Release.self, from: data).tag_name
  }

  struct CheckError: LocalizedError {
    let errorDescription: String?
  }

  /// "v0.2.0" → [0, 2, 0]. What follows a "-" or "+" is left out: the old tags' build
  /// ("v0.1-43" → [0, 1]) and pre-release labels.
  nonisolated static func numbers(_ version: String) -> [Int]? {
    var text = Substring(version)
    if text.first == "v" || text.first == "V" { text = text.dropFirst() }
    let parts = text.prefix { $0 != "-" && $0 != "+" }.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.compactMap { $0 }
  }

  nonisolated static func isNewer(_ version: String, than other: String) -> Bool {
    guard let a = numbers(version), let b = numbers(other) else { return false }
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  /// "v0.3.0" → "0.3.0".
  nonisolated static func displayVersion(_ tag: String) -> String {
    tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag
  }
}
