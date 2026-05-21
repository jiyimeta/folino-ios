#if os(Android)
import Domain
import Foundation
import Observation

// MARK: - Lifecycle

@_cdecl("folino_library_store_create")
public func folino_library_store_create() -> UnsafeMutableRawPointer {
    let store = MainActor.assumeIsolated {
        LibraryStore(
            repository: StubScoreLibraryRepository(),
            importer: StubScoreFileImporter(),
            gateway: StubScoreFileGateway(),
            shareService: StubScoreShareService(),
        )
    }
    return Unmanaged.passRetained(store).toOpaque()
}

@_cdecl("folino_library_store_destroy")
public func folino_library_store_destroy(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<LibraryStore>.fromOpaque(ptr).release()
}

// MARK: - Score list snapshot

@_cdecl("folino_library_store_set_search_text")
public func folino_library_store_set_search_text(
    _ ptr: UnsafeMutableRawPointer,
    _ cstr: UnsafePointer<CChar>,
) {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    let s = String(cString: cstr)
    MainActor.assumeIsolated {
        AndroidLibraryHolder.shared.scoreListStore(for: store).searchQuery = s
    }
}

@_cdecl("folino_library_store_displayed_items_string")
public func folino_library_store_displayed_items_string(
    _ ptr: UnsafeMutableRawPointer,
) -> UnsafeMutablePointer<CChar> {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    let list: [ScoreItem] = MainActor.assumeIsolated {
        AndroidLibraryHolder.shared.scoreListStore(for: store).displayedItems
    }
    let joined = list.map { item in
        "\(item.id.rawValue.uuidString)|\(item.title)|\(item.composer ?? "")"
    }.joined(separator: ";")
    // strdup allocates on the C heap; the caller must free via folino_library_free_cstring.
    // swiftlint:disable:next force_unwrapping
    return strdup(joined)!
}

@_cdecl("folino_library_free_cstring")
public func folino_library_free_cstring(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

// MARK: - Observation → callback bridge

/// Box for C interop values that are safe to pass across concurrency domains for JNI callbacks.
/// UnsafeMutableRawPointer and C function pointers are inherently unsafe — this is an Android-only
/// JNI bridge where the caller (JVM) owns the lifetime. @unchecked Sendable is appropriate here.
struct JNICallbackBox: @unchecked Sendable {
    let contextBits: Int
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void

    var context: UnsafeMutableRawPointer? {
        contextBits == 0 ? nil : UnsafeMutableRawPointer(bitPattern: contextBits)
    }
}

@_cdecl("folino_library_store_observe_displayed_items")
public func folino_library_store_observe_displayed_items(
    _ ptr: UnsafeMutableRawPointer,
    _ context: UnsafeMutableRawPointer?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?) -> Void,
) {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    let box = JNICallbackBox(
        contextBits: context.map { Int(bitPattern: $0) } ?? 0,
        callback: callback,
    )
    MainActor.assumeIsolated {
        AndroidLibraryHolder.shared.observe(store: store, box: box)
    }
}

// MARK: - AndroidLibraryHolder

/// Lazily creates and caches a `ScoreListStore` per `LibraryStore`, and re-arms the
/// `withObservationTracking` callback loop on each change so the Android side stays notified.
@MainActor
final class AndroidLibraryHolder {
    static let shared = AndroidLibraryHolder()

    private var listStores: [ObjectIdentifier: ScoreListStore] = [:]
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    func scoreListStore(for store: LibraryStore) -> ScoreListStore {
        let key = ObjectIdentifier(store)
        if let existing = listStores[key] {
            return existing
        }
        let listStore = store.makeScoreListStore(source: .all)
        listStores[key] = listStore
        return listStore
    }

    func observe(store: LibraryStore, box: JNICallbackBox) {
        let listStore = scoreListStore(for: store)
        let armCallback: () -> Void = { [weak listStore] in
            guard let listStore else { return }
            withObservationTracking {
                _ = listStore.displayedItems
            } onChange: {
                Task { @MainActor in
                    box.callback(box.context)
                    AndroidLibraryHolder.shared.observers[ObjectIdentifier(listStore)]?()
                }
            }
        }
        observers[ObjectIdentifier(listStore)] = armCallback
        armCallback()
    }
}

#endif
