import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

/// What a `ScoreShareTarget` becomes on macOS. Pure, so the single-vs-multiple decision and the default filename are
/// testable without a window.
enum ScoreExportPlan: Equatable {
    case nothing
    /// A save panel, seeded with the file's own name minus its extension — the extension comes from `contentTypes`.
    case single(url: URL, defaultFilename: String)
    /// A folder chooser: a save panel names one destination, and several files need a directory.
    case multiple(urls: [URL])

    init(urls: [URL]) {
        switch urls.count {
        case 0:
            self = .nothing
        case 1:
            let url = urls[0]
            self = .single(url: url, defaultFilename: url.deletingPathExtension().lastPathComponent)
        default:
            self = .multiple(urls: urls)
        }
    }
}

/// Presents a `ScoreShareTarget`. The whole platform split lives here, so no call site carries an `#if` in its
/// modifier chain — the house rule from `UtilityUI/PlatformToolbarCompat.swift`, and the thing SwiftFormat's
/// `--ifdef no-indent` fights when it is broken.
///
/// **iOS presents the system share sheet; macOS presents a save panel.** Not a arbitrary difference: on iPhone the
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

    /// `.data` rather than a per-file type: a target can mix formats (bulk share of PDF + MSCZ), and the URLs already
    /// carry their own extensions, which is what the exporter writes.
    private var contentTypes: [UTType] {
        [.data]
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
