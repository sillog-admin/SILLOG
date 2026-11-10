import SwiftUI

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
            Text(title).font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            Text(description).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.gray)
                TextField("\(title) 검색", text: $query)
                    .textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.gray)
                    }.buttonStyle(.plain).accessibilityLabel("검색어 지우기")
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
    @ViewBuilder let items: () -> Items

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Brand.suit(13, .semibold)).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 440), spacing: 15)], spacing: 7, content: items)
        }
    }
}

struct CatalogRow<Icon: View, Actions: View>: View {
    let title: String
    let subtitle: String
    let open: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 10) {
                    icon().accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                        Text(subtitle).font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            actions()
        }
        .padding(.horizontal, 8)
        .hoverHighlight(cornerRadius: 9)
    }
}
