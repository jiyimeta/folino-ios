import AppKit

/// The one piece of AppKit lifecycle the Mac shell owns: an edit made within the autosave debounce of ⌘Q must reach
/// the disk. Every window's `onDisappear` flushes on close; quitting the app does not reliably reach those, so
/// termination is deferred until every live editor has flushed (design §2.1).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await MacEditorRegistry.shared.flushAll(timeout: .seconds(5))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
