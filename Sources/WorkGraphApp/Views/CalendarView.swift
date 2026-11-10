import SwiftUI
import WorkGraphCore

/// 메인 창 '캘린더': 가운데 웹 달력(일·주·월, 연결한 캘린더의 일정과 점선 제안), 오른쪽에 일정 제안 카드와 연결한 캘린더 목록(체크로 보이기·숨기기)
struct CalendarView: View {
    static let panelWidth: CGFloat = 300
    @ObservedObject private var calendar = CalendarService.shared

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                CalendarWebView(calendar: calendar)
                if !calendar.granted && !calendar.googleConnected { permissionCard }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Brand.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    suggestionSection
                    calendarSection.padding(.top, 28)
                }
                .padding(.horizontal, 20).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.panelWidth)
        }
        .background(Color.white)
        .onAppear { calendar.refresh() }
    }

    // MARK: 권한

    private var permissionCard: some View {
        VStack(spacing: 10) {
            Text("캘린더 권한을 켜면 연결한 캘린더의 일정이 보여요").font(Brand.suit(14, .semibold)).foregroundStyle(Brand.text)
            Text("기록에서 찾은 일정 제안은 권한 없이도 보여요").font(Brand.suit(12)).foregroundStyle(Brand.gray)
            Button { Task { await calendar.requestAccess() } } label: {
                Text("허용하기").font(Brand.suit(12.5, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 32).background(Capsule().fill(Brand.text)).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white).shadow(color: Color.black.opacity(0.08), radius: 16, y: 6))
    }

    // MARK: 일정 제안

    private var suggestionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("일정 제안", count: calendar.suggestions.count)
            if calendar.granted || calendar.googleConnected { targetPicker }
            if calendar.suggestions.isEmpty {
                Text("기록에서 찾은 일정이 없어요").font(Brand.suit(12)).foregroundStyle(Brand.gray)
            } else {
                ForEach(calendar.suggestions) { card($0) }
            }
        }
    }

    /// 달력의 점선 제안과 같은 점선 테두리
    private func card(_ suggestion: EventSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(suggestion.title).font(Brand.suit(13, .semibold)).foregroundStyle(Brand.text).lineLimit(2)
            Text(CalendarService.dateText(suggestion)).font(Brand.suit(11.5)).foregroundStyle(Brand.gray)
            if !suggestion.evidence.isEmpty {
                Text(suggestion.evidence).font(Brand.suit(11.5)).foregroundStyle(Brand.tabText).lineLimit(2)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button { calendar.dismiss(suggestion) } label: {
                    Text("무시").font(Brand.suit(11.5)).foregroundStyle(Brand.gray).padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await calendar.register(suggestion) } } label: {
                    Text("등록").font(Brand.suit(11.5, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 26).background(Capsule().fill(Brand.text)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x8A7566).opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    /// [등록]이 넣을 캘린더 고르기: 실록(기본) 또는 일정을 넣을 수 있는 캘린더 (구글 계정의 캘린더 포함). 메뉴 막대·알림의 [등록]도 같은 곳
    private var targetPicker: some View {
        let writable = calendar.sources.filter(\.writable)
        let groups = writable.map(\.account).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return HStack(spacing: 6) {
            Text("등록할 캘린더").font(Brand.suit(11.5)).foregroundStyle(Brand.gray)
            Menu {
                Button("\(CalendarService.calendarName) (기본)") { calendar.setTarget(nil) }
                ForEach(groups, id: \.self) { account in
                    Section(account.isEmpty ? "이 Mac" : account) {
                        ForEach(writable.filter { $0.account == account }) { source in
                            Button(source.title) { calendar.setTarget(source.id) }
                        }
                    }
                }
            } label: {
                Text(calendar.target.map { "\($0.title) · \($0.account)" } ?? CalendarService.calendarName)
                    .font(Brand.suit(11.5, .medium)).foregroundStyle(Brand.text).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: 연결한 캘린더

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("연결한 캘린더", count: nil)
            if !calendar.granted {
                Text("캘린더 권한이 없어 맥 캘린더를 읽지 못해요").font(Brand.suit(12)).foregroundStyle(Brand.gray)
            }
            if calendar.sources.isEmpty {
                if calendar.granted { Text("연결한 캘린더가 없어요").font(Brand.suit(12)).foregroundStyle(Brand.gray) }
            } else {
                ForEach(accounts, id: \.self) { account in
                    Text(account.isEmpty ? "이 Mac" : account).font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 6)
                    ForEach(calendar.sources.filter { $0.account == account }) { row($0) }
                }
            }
            googleControls.padding(.top, 12)
            Text("구글 캘린더는 시스템 설정 > 인터넷 계정에 추가해도 여기에 보여요").font(Brand.suit(11)).foregroundStyle(Brand.sub)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }

    /// 맥에 구글을 안 붙인 사람용: 앱에서 구글 계정을 바로 연결·끊기. 이 빌드에 구글 클라이언트 ID 가 없으면 안내만
    @ViewBuilder
    private var googleControls: some View {
        if calendar.googleConnected {
            Button { calendar.disconnectGoogle() } label: {
                Text("구글 연결 끊기").font(Brand.suit(11.5)).foregroundStyle(Brand.gray).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if calendar.googleAvailable {
            Button { Task { await calendar.connectGoogle() } } label: {
                Text(calendar.googleBusy ? "브라우저에서 승인하는 중…" : "구글 계정 연결").font(Brand.suit(12, .medium)).foregroundStyle(Brand.text)
                    .padding(.horizontal, 14).frame(height: 28).overlay(Capsule().strokeBorder(Brand.line)).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(calendar.googleBusy)
        } else {
            Text("구글 계정을 바로 연결하려면 앱에 구글 클라이언트 ID가 필요해요").font(Brand.suit(11)).foregroundStyle(Brand.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = calendar.googleError {
            Text(error).font(Brand.suit(11)).foregroundStyle(Color(hex: 0xC0573F)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accounts: [String] {
        calendar.sources.map(\.account).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private func row(_ source: CalendarFeed.Source) -> some View {
        let visible = !calendar.hidden.contains(source.id)
        let color = Color(hex: UInt32(source.color.dropFirst(), radix: 16) ?? 0x8A7566)
        return Button { calendar.setVisible(source.id, !visible) } label: {
            HStack(spacing: 8) {
                Image(systemName: visible ? "checkmark.square.fill" : "square").font(.system(size: 13)).foregroundStyle(color)
                Text(source.title).font(Brand.suit(12.5)).foregroundStyle(visible ? Brand.text : Brand.gray).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Brand.suit(13, .bold)).foregroundStyle(Brand.text)
            if let count, count > 0 { Text("\(count)").font(Brand.suit(12, .semibold)).foregroundStyle(Brand.gray) }
        }
    }
}
