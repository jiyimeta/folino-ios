import SwiftUI

public struct CollapsibleSection<Content: View, Header: View, Footer: View>: View {
    @Binding private var isExpanded: Bool
    private let count: Int?
    private let content: () -> Content
    private let header: () -> Header
    private let footer: (Bool) -> Footer

    public init(
        isExpanded: Binding<Bool>,
        count: Int? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder footer: @escaping (_ isExpanded: Bool) -> Footer,
    ) {
        _isExpanded = isExpanded
        self.count = count
        self.content = content
        self.header = header
        self.footer = footer
    }

    public var body: some View {
        Section {
            if isExpanded {
                content()
            }
        } header: {
            CollapsibleSectionHeader(isExpanded: $isExpanded) {
                HStack {
                    header()
                    Spacer()
                    if let count {
                        Text(count, format: .number).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            footer(isExpanded)
        }
    }
}

extension CollapsibleSection {
    public init(
        isExpanded: Binding<Bool>,
        count: Int? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder header: @escaping () -> Header,
    ) where Footer == EmptyView {
        self.init(
            isExpanded: isExpanded,
            count: count,
            content: content,
            header: header,
            footer: { _ in EmptyView() },
        )
    }
}

private struct CollapsibleSectionHeader<Label: View>: View {
    @Binding var isExpanded: Bool

    let label: () -> Label

    var body: some View {
        Button {
            withAnimation(.smooth()) { isExpanded.toggle() }
        } label: {
            HStack {
                label()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var isExpanded = true

    Form {
        CollapsibleSection(isExpanded: $isExpanded, count: 4) {
            ForEach(0 ..< 4) { i in
                Text(verbatim: "Item \(i)")
            }
        } header: {
            HStack {
                Text(verbatim: "Title")
            }
        } footer: { isExpanded in
            Text(verbatim: "Footer (isExpanded: \(isExpanded))")
        }
    }
}
