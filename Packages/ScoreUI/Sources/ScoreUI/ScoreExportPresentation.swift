import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

/// What a `ScoreShareTarget` becomes on macOS. Pure, so the single-vs-multiple decision and the default filename are
/// testable without a window.
enum ScoreExportPlan: Equatable {
    case nothing
    /// A save panel, seeded with the file's own name — extension included, since `defaultFilename` is the only
    /// mechanism here that carries one through to the saved file.
    case single(url: URL, defaultFilename: String)
    /// A folder chooser: a save panel names one destination, and several files need a directory.
    case multiple(urls: [URL])

    init(urls: [URL]) {
        switch urls.count {
        case 0:
            self = .nothing
        case 1:
            let url = urls[0]
            self = .single(url: url, defaultFilename: url.lastPathComponent)
        default:
            self = .multiple(urls: urls)
        }
    }
}

/// Presents a `ScoreShareTarget`. The whole platform split lives here, so no call site carries an `#if` in its
/// modifier chain — the house rule from `UtilityUI/PlatformToolbarCompat.swift`, and the thing SwiftFormat's
/// `--ifdef no-indent` fights when it is broken.
///
/// **iOS presents the system share sheet; macOS presents a save panel.** Not an arbitrary difference: on iPhone the
/// share sheet *is* the filesystem — Mail, AirDrop and Messages are how a file leaves. On a Mac "put this where I
/// said" is the primary act and Finder owns everything downstream, so routing a file through a sharing service to
/// reach a folder is the long way round. Umbrella spec §8: capability does not vary by platform, placement does.
struct ScoreExportPresentation: ViewModifier {
    @Binding var target: ScoreShareTarget?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: $target) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
        #else
        content
            .fileExporter(
                isPresented: isPresentedBinding,
                item: singleItem,
                contentTypes: contentTypes,
                defaultFilename: defaultFilename,
            ) { _ in target = nil }
            .fileExporter(
                isPresented: isMultipleBinding,
                items: multipleItems,
                contentTypes: contentTypes,
            ) { _ in target = nil }
        #endif
    }

    #if os(macOS)
    private var plan: ScoreExportPlan {
        ScoreExportPlan(urls: target?.urls ?? [])
    }

    /// Resolved per-URL from each file's own extension, not hardcoded: a target can mix formats (bulk share of PDF +
    /// MSCZ), and `UTType(filenameExtension:)` picks up the score UTIs the Mac `Info.plist` declares. The extension
    /// itself is carried by `defaultFilename` / the URLs' own names — `contentTypes` only tells the panel what kind
    /// of file this is, it does not by itself put an extension on anything. Falls back to `.data` for an unknown
    /// extension, which is also what an empty target collapses to.
    private var contentTypes: [UTType] {
        let resolved = (target?.urls ?? []).map { UTType(filenameExtension: $0.pathExtension) ?? .data }
        return resolved.isEmpty ? [.data] : resolved
    }

    private var singleItem: URL? {
        if case let .single(url, _) = plan {
            url
        } else {
            nil
        }
    }

    private var defaultFilename: String? {
        if case let .single(_, name) = plan {
            name
        } else {
            nil
        }
    }

    private var multipleItems: [URL] {
        if case let .multiple(urls) = plan {
            urls
        } else {
            []
        }
    }

    private var isPresentedBinding: Binding<Bool> {
        Binding(
            get: {
                if case .single = plan {
                    true
                } else {
                    false
                }
            },
            set: {
                if !$0 {
                    target = nil
                }
            },
        )
    }

    private var isMultipleBinding: Binding<Bool> {
        Binding(
            get: {
                if case .multiple = plan {
                    true
                } else {
                    false
                }
            },
            set: {
                if !$0 {
                    target = nil
                }
            },
        )
    }
    #endif
}

extension View {
    /// Presents the score files a `ScoreShareTarget` carries: a share sheet on iOS, a save panel or folder chooser on
    /// macOS. Clears the binding when the presentation finishes, cancelled or not.
    public func scoreExportPresentation(target: Binding<ScoreShareTarget?>) -> some View {
        modifier(ScoreExportPresentation(target: target))
    }
}
