import SwiftUI
import SillogCore

struct CatalogHeader<Actions: View>: View {
    let title: String
    let description: String
    @Binding var query: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                heading
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                controls
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            Text(description).font(Brand.font(.body)).foregroundStyle(Brand.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.gray)
                TextField(tr("\(title) 검색"), text: $query)
                    .textFieldStyle(.plain).font(Brand.font(.body)).foregroundStyle(Brand.text)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.gray)
                    }.buttonStyle(.plain).accessibilityLabel(tr("검색어 지우기"))
                }
            }
            .padding(.horizontal, 12).frame(width: 190, height: 32)
            .background(.white, in: Capsule())
            .overlay { Capsule().strokeBorder(Brand.line).allowsHitTesting(false) }
            actions()
        }.fixedSize(horizontal: true, vertical: false)
    }
}

struct CatalogSection<Items: View>: View {
    let title: String
    /// Fixed column count; nil fits 290-440pt columns to the width.
    var columns: Int? = nil
    @ViewBuilder let items: () -> Items

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Brand.font(.rowTitle, .semibold)).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns.map { Array(repeating: GridItem(.flexible(), spacing: 20), count: $0) }
                      ?? [GridItem(.adaptive(minimum: 290, maximum: 440), spacing: 15)],
                      spacing: columns == nil ? 7 : 10, content: items)
        }
    }
}

struct CatalogRow<Icon: View, Actions: View>: View {
    let title: String
    let subtitle: String
    var large = false
    let open: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: large ? 14 : 10) {
                    icon().accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: large ? 5 : 3) {
                        Text(title).font(Brand.font(large ? .sectionTitle : .rowTitle)).foregroundStyle(Brand.ink).lineLimit(1)
                        Text(subtitle).font(Brand.font(large ? .body : .caption)).foregroundStyle(Brand.gray).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: large ? 68 : 48, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            actions()
        }
        .padding(.horizontal, 8)
        .hoverHighlight(cornerRadius: 9)
    }
}
