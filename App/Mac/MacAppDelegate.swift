import AppKit

/// The AppKit lifecycle the Mac shell owns.
///
/// **Flushing**: an edit made within the autosave debounce of ⌘Q must reach the disk. Every window's `onDisappear`
/// flushes on close; quitting the app does not reliably reach those, so termination is deferred until every live
/// editor has flushed (design §2.1).
///
/// **Quitting is not "the last score window closed"**: ⌘Q closes every window, and each close would otherwise run
/// §2.9.5 and summon the library on the way out. The flag is set before the reply is deferred, so it is already true
/// by the time any window closes.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { MacScoreWindowRegistry.shared.isTerminating = true }
        Task { @MainActor in
            await MacEditorRegistry.shared.flushAll(timeout: .seconds(5))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
