import AppKit
import Foundation

/// Work handed to a detached shell that outlives this process.
///
/// Two features need the same awkward thing: something has to happen *after*
/// this app has exited, and this app is the only one that knows it should.
/// Relaunching for a permission grant needs the bundle opened once the old
/// process is gone; installing an update needs the bundle replaced first, and
/// replacing a running app's own bundle underneath itself is not something to
/// find out the hard way.
///
/// So both spawn `/bin/sh`, detached, whose first job is to wait for this pid
/// to disappear. Polling `kill -0` at 200 ms is crude and is the right amount
/// of machinery: the alternative is a launch agent or a helper tool, which is a
/// lot of moving parts for a loop that runs for under a second and then exits.
///
/// Paths go in as single-quoted shell words rather than double-quoted ones. The
/// bundle is at `/Applications/Pixel Pilot.app`, and while a space is handled
/// either way, `$` and backticks are not — and the destination is only ever as
/// trustworthy as `Bundle.main.bundleURL`, which a user can rename.
enum RelaunchHandoff {
  /// Waits for this process to exit, then opens `bundle` again.
  static func relaunch(bundle: URL) {
    run(script: "\(waitForExit); \(open(bundle))")
  }

  /// Waits for this process to exit, replaces `bundle` with `replacement`, then
  /// opens it.
  ///
  /// `ditto` rather than `mv` or `cp -R`: it is the tool that preserves
  /// extended attributes and the resource forks a signed bundle carries, and
  /// getting that wrong produces an app whose signature no longer verifies —
  /// which on this app means the Accessibility grant is not merely reset but
  /// unobtainable.
  ///
  /// The old bundle is moved aside rather than deleted first. If `ditto` fails
  /// halfway there is still a complete app on disk to put back, where deleting
  /// first would leave nothing at all and no way to say so — this script has no
  /// window to report into.
  static func replaceAndRelaunch(bundle: URL, with replacement: URL) {
    run(script: """
      \(waitForExit)
      \(swap(bundle: bundle, with: replacement))
      \(open(bundle))
      """)
  }

  /// The swap on its own, without the waiting or the reopening.
  ///
  /// Separated so `RelaunchHandoffTests` can run the real script against a
  /// throwaway bundle. A test that checked a second copy of these lines would
  /// only be checking that the copy was made correctly.
  static func swap(bundle: URL, with replacement: URL) -> String {
    let target = quoted(bundle.path)
    let source = quoted(replacement.path)
    let backup = quoted(bundle.path + ".old")

    return """
      rm -rf \(backup)
      if mv \(target) \(backup); then
        if /usr/bin/ditto \(source) \(target); then
          rm -rf \(backup)
        else
          rm -rf \(target)
          mv \(backup) \(target)
        fi
      fi
      """
  }

  // MARK: - Pieces

  private static var waitForExit: String {
    let pid = ProcessInfo.processInfo.processIdentifier
    return "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done"
  }

  private static func open(_ bundle: URL) -> String {
    "/usr/bin/open \(quoted(bundle.path))"
  }

  /// A path as one shell word, with any single quote in it escaped.
  private static func quoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  private static func run(script: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try? process.run()
  }
}
