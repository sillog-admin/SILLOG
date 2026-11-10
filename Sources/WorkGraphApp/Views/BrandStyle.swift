import SwiftUI
import AppKit
import WorkGraphCore

/// Figma 화면 모음(358:1535) 공용 값. 모든 탭이 이 파일의 색, 글꼴, 유리 표면을 쓴다.
enum Brand {
    static let ink = Color(hex: 0x24150F)          // 주색: 제목, 강조 버튼
    static let text = Color(hex: 0x141210)         // 먹: 본문, 입력값
    static let gray = Color(hex: 0x736D68)         // 회색: 보조 글씨, 눈썹 글씨
    static let tabText = Color(hex: 0x4A4541)      // 선택 안 된 탭, 보조 버튼 글씨
    static let line = Color(hex: 0xE5E2DF)         // 구분선, 입력칸 테두리
    static let sky = Color(hex: 0xB4D0E4)          // 보조색 하늘: 배지 테두리, 세션 고리
    static let sub = Color(hex: 0xAAAAAA)          // 자리표시 글씨
    // 창 머리와 아이콘 줄 (Figma 851:354, 851:329). 짙은 ink 를 큰 면에 깔지 않고 갈색 계열로 채운다
    static let accent = Color(hex: 0x8A7566)       // 주 단추 바탕 (흰 글씨)
    static let accentDark = Color(hex: 0x6E5A4D)   // 주 단추에 커서를 올렸을 때처럼 더 짙어야 할 곳
    static let badgeFill = Color(hex: 0xEAE3DC)    // 작은 배지와 계정 동그라미 바탕
    static let badgeText = Color(hex: 0x5E4B40)    // 배지 글씨
    static let pillFill = Color(hex: 0xE6E1DB)     // 창 머리 보조 알약 바탕
    // 고른 알약(칩, Figma ST-03). 고른 것: chipSelectedFill 바탕 + 1pt chipSelectedBorder 테두리 + chipSelectedText 글자(굵기 medium).
    // 안 고른 것: chipFill 바탕 + tabText 글자. 진한 갈색 채움과 흰 글자는 주요 동작 단추(accent)만 쓴다
    static let chipFill = Color(hex: 0xF3F1EF)             // 안 고른 알약 바탕
    static let chipSelectedFill = Color(hex: 0xEAE3DC)     // 고른 알약 바탕
    static let chipSelectedBorder = Color(hex: 0xCCBEB3)   // 고른 알약 1pt 테두리
    static let chipSelectedText = Color(hex: 0x3D2F27)     // 고른 알약 글자
    static let connected = Color(hex: 0x3D9B6B)    // 연결됨 점
    /// 유리 바탕(창 뒤 바탕화면 흐림) 위에 얹는 흰색 양. 낮을수록 바탕화면이 더 비친다
    static let glassTint = 0.08
    static let hairline = Color(red: 20 / 255, green: 18 / 255, blue: 16 / 255).opacity(0.08)

    enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold" }
    /// 한글 본문 글꼴 SUIT (없으면 시스템 글꼴로 대체된다)
    static func suit(_ size: CGFloat, _ weight: Weight = .regular) -> Font { .custom("SUIT-\(weight.rawValue)", size: size) }
    static let paper = Color(hex: 0xF6F5F4)        // 칩과 오류 상자 바탕, 예전 스타일 창 바탕 (OUT-W1)
    static let blue = Color(hex: 0x5E97C8)         // 켜짐 체크, 폴더, 성공 표시, 사용량 막대

    /// 영문 눈썹 글씨와 숫자 Jost 400. 앱에 넣은 Jost* 판에서 400 의 이름은 "Jost-Book" (FontRegistryTests 가 확인)
    static func jost(_ size: CGFloat) -> Font { .custom("Jost-Book", size: size) }
    /// 큰 숫자 Jost 200 (Figma 의 ExtraLight, 앱에 넣은 판의 이름은 "Jost-Thin")
    static func jostLight(_ size: CGFloat) -> Font { .custom("Jost-Thin", size: size) }

    /// Resources/Brand 안 PNG 한 장 (없으면 nil)
    private static func brandImage(_ name: String) -> NSImage? {
        let url = BundledResources.url(forResource: name, withExtension: "png", subdirectory: "Brand", main: .main) { .module }
        return url.flatMap(NSImage.init(contentsOf:))
    }
    static let wordmark: NSImage? = brandImage("wordmark")
    /// 브랜드 심볼 (시스템이 씌우는 회색 판 없음)
    static let iconMatte: NSImage? = brandImage("icon")
    /// 눈을 지운 심볼. GazingMark 가 위에 눈을 그린다
    static let iconBody: NSImage? = brandImage("icon_body")
    /// OpenAI 마크: 검은 한 색 판이라 template 로 칠해 쓴다
    static let openAIMark: NSImage? = brandImage("openai_mark")
    /// Claude 로고 (24 칸 SVG 경로, 채워 그린다)
    static let claudePath = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
}

/// 앱에 넣은 SUIT·Jost 글꼴(Resources/Brand/Fonts)을 이 프로세스에만 등록한다. 못 찾으면 시스템 글꼴로 그려진다.
enum BrandFonts {
    @discardableResult
    static func register() -> [String] {
        // .app 은 Contents/Resources/Brand 만 본다 (.app 에서 Bundle.module 을 부르면 리소스 번들이 없어 앱이 끝난다)
        let directory = BundledResources.url(forResource: "Fonts", withExtension: nil, subdirectory: "Brand", main: .main) { .module }
        return directory.map { FontRegistry.register(directory: $0) } ?? []
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// 눈썹 글씨: 기기 코드, 요약 같은 작은 구역 제목
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.suit(11, .semibold)).foregroundStyle(Brand.gray)   // 한글 눈썹 글씨
    }
}

/// 탭 첫머리: 한 줄에 제목(22)과 설명(12), 오른쪽 추가 요소. 아래 구분선.
struct BrandPageHeader<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {           // 제목과 설명은 한 줄
                    Text(title).font(Brand.suit(22, .semibold)).tracking(-0.66).foregroundStyle(Brand.ink)
                    if let detail { Text(detail).font(Brand.suit(12)).foregroundStyle(Brand.gray).lineLimit(1) }
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 34)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

extension BrandPageHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// 위쪽 글자 탭: 기록 자료(파일 · 보관함 · 활동 로그)와 설정(일반 · AI 연결)의 머리. 고른 탭은 진한 글씨에 옅은 회색 알약.
/// badge 가 0 보다 크면 탭 이름 옆에 하늘색 숫자 (대기 중인 파일 제안)
struct TextTabs<Item: Hashable & Identifiable & CaseIterable & RawRepresentable>: View where Item.RawValue == String, Item.AllCases: RandomAccessCollection {
    @Binding var selection: Item
    /// 고른 탭 알약 바탕. 기록 자료는 기본값(#F6F5F4), 설정과 활동 로그는 창 머리 색(#EFECE9) (Figma 구역 탭)
    var selectedFill: Color = ChatPalette.soft
    var badge: (Item) -> Int = { _ in 0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Item.allCases) { item in
                let on = selection == item
                Button { selection = item } label: {
                    HStack(spacing: 6) {
                        Text(item.rawValue).font(Brand.suit(14, on ? .semibold : .regular)).foregroundStyle(on ? Brand.ink : Brand.tabText)
                        if badge(item) > 0 { Text("\(badge(item))").font(Brand.jost(12)).foregroundStyle(Brand.blue) }
                    }
                    .padding(.horizontal, 13).frame(height: 32)
                    .background(Capsule().fill(on ? selectedFill : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 16, active: !on)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).frame(height: 56)
        .background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

/// 상세 판 배지: 하늘색 옅은 바탕과 테두리
struct BrandBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.suit(10, .medium)).foregroundStyle(Brand.ink)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Brand.sky.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.sky))
    }
}

/// 버튼: primary는 옅은 회색 바탕에 진한 글씨, secondary는 글자만 (둘 다 테두리 없음)
struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, kind: kind) }

    /// 커서를 대면 바탕이 한 단계 진해진다 (누르기 전에 눌릴 곳을 알 수 있게)
    private struct HoverBody: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let on = hover && enabled
            configuration.label
                .font(Brand.suit(11, .medium))
                .foregroundStyle(kind == .primary || on ? Brand.ink : Brand.tabText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(kind == .primary ? Color(hex: on ? 0xEBE8E5 : 0xF3F1EF) : on ? Color(hex: 0xF3F1EF) : .clear))   // 주 단추는 옅은 회색 바탕, 보조 단추는 글자만
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        }
    }
}

/// 커서를 대면 옅은 회색 둥근 바탕이 깔린다. 누를 수 있는 줄, 아이콘, 글자 단추에 공통으로 쓴다
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    var active = true
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(hover && active ? 0.045 : 0)))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}


extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8, active: Bool = true) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius, active: active)) }
}

extension View {
    /// 유리 막대 바탕 (탭 막대, 사이드바): 창 바탕의 유리가 그대로 보이게 하고 흰색만 조금(Brand.glassTint) 얹는다.
    /// 여기서 유리를 한 겹 더 깔면 두 겹이 돼 뒤가 비치지 않는다
    func brandGlass() -> some View {
        background(.white.opacity(Brand.glassTint))
    }

    /// 유리 판: 내용 위에 떠 있는 판 (자기 유리를 깔고 흰색 조금과 얇은 테두리를 얹는다). 창 가장자리 사이드바는 brandGlass 를 쓴다
    func glassPanel(cornerRadius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Brand.hairline))
    }

    /// 유리 알약: 선택한 탭과 선택한 항목 (흰색 78%, 얇은 테두리, 옅은 그림자)
    @ViewBuilder func glassPill(_ on: Bool, cornerRadius: CGFloat = 8) -> some View {
        if on {
            background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(0.78))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.06)))
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 4)
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            )
        } else {
            self
        }
    }

    /// 입력칸과 선택 상자: 상자 없이 아래 밑줄 하나
    func brandField(height: CGFloat = 35) -> some View {
        frame(height: height)
            .padding(.horizontal, 2)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }   // 상자 대신 밑줄 하나
    }
}

/// 24칸 SVG 경로(lucide 아이콘)를 그리는 모양. 줄 아이콘이라 stroke 로 그린다.
/// ponytail: 호는 원호(rx == ry, 회전 0)만 다룬다. lucide 에는 그것뿐이다. 타원 호가 필요하면 그때 늘린다
struct SVGIcon: Shape {
    let d: String

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var nums = [CGFloat](), cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero, lastC2: CGPoint?
        let s = rect.width / 24, ox = rect.minX, oy = rect.minY
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        // 명령 글자와 숫자로 쪼갠다 ("1-2", ".5.5" 같은 붙은 숫자도)
        var tokens = [(Character?, CGFloat?)]()
        let chars = Array(d), n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c.isLetter { tokens.append((c, nil)); i += 1 }
            else if c == "-" || c == "." || c.isNumber {
                var j = i + 1
                var dot = c == "."
                while j < n, chars[j].isNumber || (chars[j] == "." && !dot) { if chars[j] == "." { dot = true }; j += 1 }
                tokens.append((nil, CGFloat(Double(String(chars[i..<j])) ?? 0))); i = j
            } else { i += 1 }
        }
        func arity(_ c: Character) -> Int {
            switch c.lowercased().first! { case "m", "l", "t": 2; case "h", "v": 1; case "c": 6; case "s", "q": 4; case "a": 7; default: 0 }
        }
        func run() {
            let rel = cmd.isLowercase
            let a = nums
            switch cmd.lowercased().first! {
            case "m": cur = rel ? pt2(cur, a[0], a[1], s) : CGPoint(x: ox + a[0] * s, y: oy + a[1] * s); start = cur; path.move(to: cur); cmd = rel ? "l" : "L"
            case "l": cur = rel ? pt2(cur, a[0], a[1], s) : pt(a[0], a[1]); path.addLine(to: cur)
            case "h": cur = CGPoint(x: rel ? cur.x + a[0] * s : ox + a[0] * s, y: cur.y); path.addLine(to: cur)
            case "v": cur = CGPoint(x: cur.x, y: rel ? cur.y + a[0] * s : oy + a[0] * s); path.addLine(to: cur)
            case "c", "s":
                let b = cmd.lowercased() == "s" ? [0, 0] + a : a
                let base = rel ? cur : CGPoint(x: ox, y: oy), k = s
                let c1 = cmd.lowercased() == "s" ? CGPoint(x: 2 * cur.x - (lastC2?.x ?? cur.x), y: 2 * cur.y - (lastC2?.y ?? cur.y))
                                                 : CGPoint(x: base.x + b[0] * k, y: base.y + b[1] * k)
                let c2 = CGPoint(x: base.x + b[2] * k, y: base.y + b[3] * k)
                cur = CGPoint(x: base.x + b[4] * k, y: base.y + b[5] * k)
                path.addCurve(to: cur, control1: c1, control2: c2); lastC2 = c2
            case "a":
                let end = rel ? pt2(cur, a[5], a[6], s) : pt(a[5], a[6])
                addArc(&path, from: cur, to: end, r: a[0] * s, large: a[3] != 0, sweep: a[4] != 0); cur = end
            default: break
            }
            if !"cs".contains(cmd.lowercased()) { lastC2 = nil }
            nums = []
        }
        for t in tokens {
            if let c = t.0 {
                if c == "z" || c == "Z" { path.closeSubpath(); cur = start; nums = []; continue }
                cmd = c; nums = []
            } else if let v = t.1 {
                nums.append(v)
                if nums.count == arity(cmd) { run() }
            }
        }
        return path
    }

    private func pt2(_ cur: CGPoint, _ dx: CGFloat, _ dy: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: cur.x + dx * s, y: cur.y + dy * s) }

    /// SVG 끝점 호를 3차 곡선 조각으로 바꿔 잇는다 (SwiftUI Path 에는 SVG 식 호가 없다)
    private func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, r r0: CGFloat, large: Bool, sweep: Bool) {
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let lam = (dx * dx + dy * dy) / (r0 * r0)
        let r = lam > 1 ? r0 * lam.squareRoot() : r0
        let sq = max(0, (r * r * r * r - r * r * (dx * dx + dy * dy)) / (r * r * (dx * dx + dy * dy)))
        let k = (large == sweep ? -1 : 1) * sq.squareRoot()
        let cx = k * dy + (p0.x + p1.x) / 2, cy = -k * dx + (p0.y + p1.y) / 2
        let a0 = atan2(p0.y - cy, p0.x - cx)
        var da = atan2(p1.y - cy, p1.x - cx) - a0
        if sweep, da < 0 { da += 2 * .pi } else if !sweep, da > 0 { da -= 2 * .pi }
        let segs = max(1, Int((abs(da) / (.pi / 2)).rounded(.up)))
        let step = da / CGFloat(segs), t = 4 / 3 * tan(step / 4)
        for j in 0..<segs {
            let s0 = a0 + step * CGFloat(j), s1 = s0 + step
            let e0 = CGPoint(x: cx + r * cos(s0), y: cy + r * sin(s0)), e1 = CGPoint(x: cx + r * cos(s1), y: cy + r * sin(s1))
            path.addCurve(to: e1,
                          control1: CGPoint(x: e0.x - t * r * sin(s0), y: e0.y + t * r * cos(s0)),
                          control2: CGPoint(x: e1.x + t * r * sin(s1), y: e1.y - t * r * cos(s1)))
        }
    }
}

/// 아이콘 줄에 쓰는 lucide 경로 (share-2, message-circle, archive, settings)
enum RailIcon {
    static let graph = "M21 5a3 3 0 1 1-6 0a3 3 0 1 1 6 0ZM9 12a3 3 0 1 1-6 0a3 3 0 1 1 6 0ZM21 19a3 3 0 1 1-6 0a3 3 0 1 1 6 0ZM8.59 13.51L15.42 17.49M15.41 6.51L8.59 10.49"
    static let chat = "M7.9 20A9 9 0 1 0 4 16.1L2 22Z"
    static let records = "M3 3H21A1 1 0 0 1 22 4V7A1 1 0 0 1 21 8H3A1 1 0 0 1 2 7V4A1 1 0 0 1 3 3ZM4 8V19A2 2 0 0 0 6 21H18A2 2 0 0 0 20 19V8M10 12H14"
    static let calendar = "M8 2V6M16 2V6M5 4H19A2 2 0 0 1 21 6V20A2 2 0 0 1 19 22H5A2 2 0 0 1 3 20V6A2 2 0 0 1 5 4ZM3 10H21"
    static let settings = "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2ZM15 12a3 3 0 1 1-6 0a3 3 0 1 1 6 0Z"
    static let connectors = "M16 12a4 4 0 1 1-8 0a4 4 0 1 1 8 0ZM16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-4 8"   // lucide at-sign (커넥터 탭, Figma 851:329)
    static let skill = "M9.94 15.5A2 2 0 0 0 8.5 14.06L2.37 12.48a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.13a.5.5 0 0 1 .96 0L14.06 8.5A2 2 0 0 0 15.5 9.94l6.13 1.58a.5.5 0 0 1 0 .96L15.5 14.06a2 2 0 0 0-1.44 1.44l-1.58 6.13a.5.5 0 0 1-.96 0Z"   // lucide sparkle
    static let link = "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"
    static let refresh = "M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8M21 3v5h-5M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16M8 16H3v5"
}

/// 스크롤 위치 표시: 시스템 막대를 숨기고 보이는 구간만 2px 선으로, 스크롤 중에만 보인다
private struct ThinScrollLight: ViewModifier {
    struct Metrics: Equatable { var offset: CGFloat; var content: CGFloat; var view: CGFloat }
    @State private var m = Metrics(offset: 0, content: 0, view: 0)
    @State private var visible = false
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .scrollIndicators(.hidden)
                .background(HideLegacyScroller())
                .onScrollGeometryChange(for: Metrics.self) { g in
                    Metrics(offset: g.contentOffset.y, content: g.contentSize.height, view: g.containerSize.height)
                } action: { old, new in
                    let moved = old.offset != new.offset
                    m = new
                    if moved { flash() }
                }
                .overlay(alignment: .topTrailing) { line }
        } else {
            content   // ponytail: macOS 14 은 onScrollGeometryChange 가 없어 시스템 막대 그대로
        }
    }

    /// 보이는 구간 선. 내용이 칸보다 짧으면 그리지 않는다
    private var line: some View {
        GeometryReader { geo in
            if m.content > m.view, m.view > 0 {
                let len = m.view / m.content
                let top = min(max(m.offset / m.content, 0), 1 - len)
                Rectangle().fill(Brand.ink.opacity(0.35))
                    .frame(width: 2, height: geo.size.height * len)
                    .offset(y: geo.size.height * top)
            }
        }
        .frame(width: 2).padding(.trailing, 3)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: visible)
        .allowsHitTesting(false)
    }

    /// 나타내고 0.8초 뒤 숨김 (스크롤이 이어지면 타이머를 다시 시작)
    private func flash() {
        visible = true
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { visible = false }
        }
    }
}

/// 마우스가 연결돼 시스템이 막대를 항상 보이는 설정(레거시)이면 .scrollIndicators(.hidden) 이 안 먹는다.
/// 같은 자리에 있는 NSScrollView 를 찾아 세로 막대를 직접 끈다 (사용자 시스템 설정은 건드리지 않음)
private struct HideLegacyScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            let mine = view.convert(view.bounds, to: nil)
            var up: NSView? = view.superview
            for _ in 0..<4 {
                guard let root = up else { return }
                if let sv = Self.scrollView(in: root, matching: mine) {
                    sv.hasVerticalScroller = false
                    return
                }
                up = root.superview
            }
        }
    }
    private static func scrollView(in root: NSView, matching rect: NSRect) -> NSScrollView? {
        if let sv = root as? NSScrollView {
            let r = sv.convert(sv.bounds, to: nil)
            if abs(r.minX - rect.minX) < 1, abs(r.width - rect.width) < 1, abs(r.height - rect.height) < 1 { return sv }
        }
        for sub in root.subviews { if let f = scrollView(in: sub, matching: rect) { return f } }
        return nil
    }
}

extension View {
    func thinScrollLight() -> some View { modifier(ThinScrollLight()) }
}

/// 브랜드 심볼. 창이 활성일 때 눈이 커서 쪽을 살짝 보고, 깜빡이고, 아래를 축으로 숨 쉬듯 흔들린다.
/// smiling 이면 눈이 웃는 모양이 된다. 동작 줄이기를 켜면 움직이지 않는다
struct GazingMark: View {
    let size: CGFloat
    var smiling = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Brand.iconBody == nil {
            if let icon = Brand.iconMatte { Image(nsImage: icon).resizable().scaledToFit().frame(width: size, height: size) }
        } else if reduceMotion {
            eyes(offset: .zero).frame(width: size, height: size)
        } else {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: activeState != .key)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    eyes(offset: gaze(center: CGPoint(x: proxy.frame(in: .global).midX, y: proxy.frame(in: .global).midY)), openness: Self.openness(at: t))
                        // 주기를 어긋나게 섞어 같은 움직임이 되풀이돼 보이지 않게 한다
                        .scaleEffect(x: 1, y: 1 + 0.012 * sin(t * 2 * .pi / 5.3), anchor: .bottom)
                        .rotationEffect(.degrees(1.6 * sin(t * 2 * .pi / 7.1) + 0.5 * sin(t * 2 * .pi / 3.1)), anchor: .bottom)
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// 눈이 뜬 정도(1 뜸, 0.1 감음). 3.7초 칸마다 칸 안의 정해진 시각에 0.18초 깜빡인다
    private static func openness(at t: TimeInterval) -> CGFloat {
        let slot = 3.7, length = 0.18
        let hash = abs(sin(floor(t / slot) * 12.9898) * 43758.5453)
        let since = t.truncatingRemainder(dividingBy: slot) - (hash - floor(hash)) * (slot - length)
        guard since >= 0, since < length else { return 1 }
        return max(0.1, abs(since / (length / 2) - 1))
    }

    private func eyes(offset: CGSize, openness: CGFloat = 1) -> some View {
        ZStack {
            Image(nsImage: Brand.iconBody!).resizable().scaledToFit()
            ForEach([0.404, 0.596], id: \.self) { x in
                Group {
                    if smiling {
                        SmileArc().stroke(.white, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                            .frame(width: size * 0.13, height: size * 0.08)
                    } else {
                        Capsule().fill(.white).frame(width: size * 0.0703, height: size * 0.1914).scaleEffect(x: 1, y: openness)
                    }
                }
                .transition(.opacity)
                .position(x: size * x + offset.width, y: size * 0.66 + offset.height)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: offset)
        .animation(.easeOut(duration: 0.15), value: smiling)
    }

    /// 창 좌표의 심볼 중심에서 커서까지의 방향으로 눈을 옮길 거리. 200pt 안에서는 가까울수록 덜 움직인다
    private func gaze(center: CGPoint) -> CGSize {
        guard let window = NSApp.keyWindow, let height = window.contentView?.bounds.height else { return .zero }
        let origin = window.convertPoint(toScreen: NSPoint(x: center.x, y: height - center.y))
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - origin.x, dy = origin.y - mouse.y              // 화면 좌표는 y 가 위로 커진다
        let distance = hypot(dx, dy)
        guard distance > 0 else { return .zero }
        let reach = size * 0.018 * min(1, distance / 200) / distance
        return CGSize(width: dx * reach, height: dy * reach)
    }
}

/// 웃는 눈: 위로 볼록한 호
private struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return path
    }
}
