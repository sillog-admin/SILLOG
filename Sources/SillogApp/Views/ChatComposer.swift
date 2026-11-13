import SwiftUI
import UniformTypeIdentifiers
import SillogCore

/// 채팅 입력: 입력 상자(+ 메뉴, 칩, 보내기) + 아래 줄(범위, 모델) + 안내문. 폭은 ChatPalette.readingWidth
struct ChatComposer: View {
    @ObservedObject var chat: ChatState
    @ObservedObject var library: LibraryState
    var modelName: String
    var openSettings: () -> Void
    var pendingRecords: Int = 0
    var tidyNow: () -> Void = {}
    var onOpenConnectors: () -> Void = {}
    var onSent: () -> Void = {}
    var onEditLast: (() -> Void)? = nil
    var showsNotice: Bool = true

    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var dictation = ChatDictation()
    @State private var micHover = false
    @State private var inputHeight: CGFloat = 38
    @State private var showPlus = false
    @State private var showFocus = false
    @State private var showConnectors = false
    @State private var showConnect = false
    @State private var showSkillPins = false
    @State private var showLibraryPicker = false
    @State private var shortcut: ChatShortcut?
    @State private var dismissedShortcut: ChatShortcut?
    @State private var shortcutIndex = 0
    @State private var shortcutMenuHeight: CGFloat = 0
    /// Tied to the focus request it was set for, so a later focus from elsewhere ignores it.
    @State private var shortcutCaret: (request: Int, range: NSRange)?
    @State private var connectedConnectors: Set<String>?
    @State private var dropTargeted = false
    @State private var plusHover = false
    @State private var previewItem: ChatLibraryItem?
    /// The answer whose follow-up the user typed over; it stays hidden after the draft is cleared.
    @State private var dismissedFollowUp: String?

    /// 이 대화에 응답이 도는 중이면 자료 설정을 잠근다
    private var busy: Bool { chat.activeMessage?.conversationID == chat.current.id }

    /// Ghost text for the empty input: the latest answer's suggested next question.
    private var followUp: String? {
        guard chat.draft.isEmpty, !busy, let last = chat.messages.last, last.role == "assistant", last.status == "complete",
              last.id != dismissedFollowUp else { return nil }
        return last.followUp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            box
            HStack(spacing: 0) {
                skillChips.padding(.leading, 12)
                Spacer(minLength: 8)
                if !modelName.isEmpty { connectionButton.padding(.trailing, 12) }
            }
            .frame(height: 20).padding(.top, 8)
            if !chat.current.scope.focus.isEmpty, chat.current.scope.useActivity, pendingRecords > 0 {
                tidyHint.padding(.top, 8).padding(.leading, 12)
            }
            if let problem = dictation.problem {
                HStack(spacing: 8) {
                    Text(problem.text).font(Brand.font(.caption)).foregroundStyle(Brand.ink).lineLimit(1)
                    if problem.settingsURL != nil {
                        ChatPillButton(title: tr("시스템 설정 열기"), systemName: "gearshape") { problem.openSettings() }
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
            }
            if !state.chatConnected {
                HStack(spacing: 8) {
                    Text(tr("AI가 연결되지 않았어요. [설정 > AI 연결]에서 먼저 연결해 주세요."))
                        .font(Brand.font(.caption)).foregroundStyle(Brand.ink).lineLimit(1)
                    ChatPillButton(title: tr("설정 열기"), systemName: "gearshape", action: openSettings)
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
            } else if showsNotice {
                Text(tr("질문과 조회한 자료는 연결한 AI로 전송돼요. 웹 검색과 커넥터는 허용한 범위만 사용해요."))
                    .font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
        .frame(maxWidth: ChatPalette.readingWidth).frame(maxWidth: .infinity)
        .sheet(isPresented: $showLibraryPicker) { LibraryPicker(library: library) { chat.attachLibraryItem($0) } }
        .onChange(of: chat.current.id) { _, _ in shortcut = nil; dismissedShortcut = nil; dismissedFollowUp = nil; dictation.cancel() }
        .onDisappear { dictation.cancel() }
        .onChange(of: chat.draft) { _, draft in if !draft.isEmpty { dismissedFollowUp = chat.messages.last?.id } }
    }

    /// 보내기가 시작됐을 때만 알린다 (프로젝트 상세에서 대화로 넘어가는 용도)
    private func send() {
        guard state.chatConnected else { return }
        // Enter finishes Whisper dictation first; its text lands in the draft only on stop.
        if dictation.holdsSpeech { dictation.stop(); return }
        if chat.send() { dictation.cancel(); shortcut = nil; onSent() }
    }

    static func placeholder(_ scope: ChatScope) -> String {
        guard scope.useActivity, !scope.focus.isEmpty else { return tr("기록을 바탕으로 무엇을 할까요?") }
        return tr("\(ChatFocusButton.summary(scope.focus))에 대해 물어보세요")
    }

    /// The chat's own artifacts stay attached for the model but are not shown as chips.
    static func shownAttachments(_ attached: [ChatLibraryItem], messages: [ConversationMessage]) -> [ChatLibraryItem] {
        let own = Set(messages.flatMap { $0.versions.flatMap(\.artifacts) }.map(\.id))
        return attached.filter { !($0.kind == "generated" && own.contains($0.originID ?? "")) }
    }

    // MARK: 입력 상자

    private var box: some View {
        let attachments = Self.shownAttachments(library.attached, messages: chat.messages)
        let paths = chat.current.scope.paths
        return VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty || !paths.isEmpty {
                // CH-18: 첨부 칩은 입력 줄 위에 줄바꿈으로 놓이고 상자가 위로 커진다. 모두 x 로 연결 해제
                ChatChipFlow(spacing: 6) {
                    ForEach(attachments) { item in
                        attachmentChip(icon: "doc", text: item.title, help: item.title, item: item,
                                       remove: library.projectAttached.contains(item.id) ? nil : { library.detach(item, conversationID: chat.current.id) })
                    }
                    ForEach(paths, id: \.self) { path in
                        attachmentChip(icon: "folder", text: URL(fileURLWithPath: path).lastPathComponent, help: path) {
                            chat.current.scope.paths.removeAll { $0 == path }
                        }
                    }
                }.padding(.top, 12).padding(.horizontal, 13)
            }
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    HStack(spacing: 8) {
                        Text(placeholder)
                            .font(Brand.font(.sectionTitle, .regular)).foregroundStyle(Brand.text.opacity(0.5)).lineLimit(1)
                        if followUp != nil && !dictation.listening {
                            Text("Tab").font(Brand.font(.tag, .medium)).foregroundStyle(Brand.gray)
                                .padding(.horizontal, 5).frame(height: 16)
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
                        }
                    }
                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
                }
                ChatInput(text: $chat.draft, height: $inputHeight, minimumHeight: 38, focusRequest: chat.inputFocusRequest,
                          selectionOnFocus: shortcutCaret.flatMap { $0.request == chat.inputFocusRequest ? $0.range : nil }, onShortcut: updateShortcut, shortcutKey: handleShortcutKey,
                          onFiles: { chat.attach($0) }, onEscape: { if dictation.listening { dictation.cancel() } else if busy { chat.cancel() } else { chat.openArtifactID = nil } }, onEditLast: onEditLast,
                          placeholder: dictation.listening ? placeholder : followUp.map { tr("추천 질문: \($0). Tab으로 입력") } ?? placeholder, onSend: send)
                    .frame(height: inputHeight)
            }
            .padding(.top, 18).padding(.horizontal, 13)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                plusButton
                micButton
                chips
                Spacer(minLength: 0)
                sendButton
            }
            .padding(.horizontal, 13).padding(.bottom, 11).padding(.top, 4)
        }
        .frame(minHeight: 96)
        .fixedSize(horizontal: false, vertical: true)   // 남는 세로 공간을 차지하지 않게: 글이 늘 때만 커진다 (Figma 96)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dropTargeted ? Brand.ink : ChatPalette.inputLine, lineWidth: dropTargeted ? 1.5 : 1))
        .sheet(item: $previewItem) { LibraryPreview(library: library, item: $0) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                chat.attach(urls)
            }
            return true
        }
        .overlay(alignment: .topLeading) {
            if shortcut != nil && !busy {
                shortcutMenu
                    .fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shortcutMenuHeight = $0 }
                    .offset(x: 12, y: -shortcutMenuHeight - 5)
            }
        }.zIndex(shortcut == nil ? 0 : 1)
    }

    private struct ShortcutChoice: Identifiable {
        let id: String
        let name: String
        let icon: String
        var connected = true
    }

    private var shortcutChoices: [ShortcutChoice] {
        guard let shortcut else { return [] }
        let choices: [ShortcutChoice]
        switch shortcut.kind {
        case .skill: choices = chat.skills.map { .init(id: $0.id, name: $0.displayTitle, icon: $0.icon) }
        case .connector:
            // Wait for the Keychain read, or connected rows act unconnected and reorder under the cursor.
            guard let connectedConnectors else { return [] }
            choices = ConnectorEntry.all.map {
                .init(id: $0.id, name: $0.name, icon: $0.icon, connected: connectedConnectors.contains($0.id))
            }
        }
        let matching = choices.filter {
            shortcut.query.isEmpty || $0.name.localizedCaseInsensitiveContains(shortcut.query) || $0.id.localizedCaseInsensitiveContains(shortcut.query)
        }
        return matching.filter(\.connected) + matching.filter { !$0.connected }
    }

    private func updateShortcut(_ value: ChatShortcut?) {
        guard value != shortcut else { return }
        if value != dismissedShortcut { dismissedShortcut = nil }
        guard value != dismissedShortcut || value == nil else { return }
        if value?.kind == .connector && shortcut?.kind != .connector {
            let ids = ConnectorEntry.all.map(\.id)
            connectedConnectors = nil
            // Off the main thread: a Keychain prompt would freeze typing while it waits.
            Task { connectedConnectors = await Task.detached { Set(ids.filter { (try? ConnectorAuth.isConnected($0)) == true }) }.value }
        }
        shortcutCaret = nil
        shortcut = value; shortcutIndex = 0
    }

    private func handleShortcutKey(_ key: UInt16) -> Bool {
        if key == 48, shortcut == nil, let followUp {
            chat.draft = followUp
            chat.inputFocusRequest += 1
            shortcutCaret = (chat.inputFocusRequest, NSRange(location: (followUp as NSString).length, length: 0))
            return true
        }
        guard let shortcut, !busy else { return false }
        let choices = shortcutChoices
        switch key {
        case 53:
            dismissedShortcut = shortcut; self.shortcut = nil
        case 125, 126:
            guard !choices.isEmpty else { return false }
            let step = key == 125 ? 1 : -1
            shortcutIndex = (shortcutIndex + step + choices.count) % choices.count
        case 36, 48, 76:
            guard choices.indices.contains(shortcutIndex) else { return key != 48 }
            chooseShortcut(choices[shortcutIndex])
        default: return false
        }
        return true
    }

    private func chooseShortcut(_ item: ShortcutChoice) {
        guard let shortcut, NSMaxRange(shortcut.range) <= (chat.draft as NSString).length else { return }
        switch shortcut.kind {
        case .skill: chat.selectSkill(item.id)
        case .connector:
            guard item.connected else { self.shortcut = nil; onOpenConnectors(); return }
            if !chat.draftConnectors.contains(item.id) { chat.draftConnectors.append(item.id) }
        }
        chat.draft = (chat.draft as NSString).replacingCharacters(in: shortcut.range, with: "")
        self.shortcut = nil
        chat.inputFocusRequest += 1
        shortcutCaret = (chat.inputFocusRequest, NSRange(location: shortcut.range.location, length: 0))
    }

    private var shortcutMenu: some View {
        let choices = shortcutChoices
        return VStack(alignment: .leading, spacing: 2) {
            Text(shortcut?.kind == .skill ? tr("스킬 선택") : tr("이번 요청의 커넥터"))
                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.horizontal, 8).padding(.vertical, 4)
            if !choices.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, item in
                                Button { chooseShortcut(item) } label: {
                                    HStack(spacing: 8) {
                                        if shortcut?.kind == .connector, let connector = ConnectorEntry.all.first(where: { $0.id == item.id }) {
                                            ConnectorLogo(connector: connector, size: 14, boxed: false)
                                        } else {
                                            Image(systemName: item.icon).font(.system(size: 12))
                                                .frame(width: 14, height: 14).accessibilityHidden(true)
                                        }
                                        Text(item.name).font(Brand.font(.caption)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        if !item.connected { Text(tr("연결 필요")).font(Brand.font(.tag)).foregroundStyle(Brand.gray) }
                                    }
                                    .padding(.horizontal, 8).frame(height: 26)
                                    .background(index == shortcutIndex ? Brand.chipSelectedFill : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(item.id)
                            }
                        }
                    }.frame(height: CGFloat(min(choices.count, 7)) * 28 - 2)
                    .onChange(of: shortcutIndex) { _, index in
                        if choices.indices.contains(index) { proxy.scrollTo(choices[index].id) }
                    }
                }
            } else if shortcut?.kind == .connector && connectedConnectors == nil {
                ProgressView().controlSize(.small).padding(8)
            } else {
                Text(tr("일치하는 항목이 없어요")).font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(8)
            }
        }
        .padding(6).frame(width: 210)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.line))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
    }

    private var plusButton: some View {
        Button { showPlus = true } label: {
            Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(Brand.tabText)
                .frame(width: 28, height: 28)
                .background(plusHover && !(busy || library.busy) ? ChatPalette.soft : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { plusHover = $0 }.disabled(busy || library.busy)
        .help(tr("자료 추가")).accessibilityLabel(tr("자료 추가"))
        .popover(isPresented: $showPlus, arrowEdge: .bottom) { plusMenu }
        .background { Color.clear.popover(isPresented: $showFocus, arrowEdge: .bottom) { ChatFocusPicker(chat: chat) } }
    }

    private var placeholder: String {
        dictation.listening ? tr("듣고 있어요…") : followUp ?? Self.placeholder(chat.current.scope)
    }

    private var micButton: some View {
        let on = dictation.listening
        return Button {
            // The caret only counts while the input has focus; otherwise speech is appended.
            let caret = (NSApp.keyWindow?.firstResponder as? ChatTextView)?.selectedRange()
            dictation.toggle(draft: $chat.draft, selection: caret, permissions: state.recordingPermissions)
        } label: {
            Group {
                if dictation.transcribing { ProgressView().controlSize(.small) }
                else { Image(systemName: on ? "mic.fill" : "mic").font(.system(size: 14)).foregroundStyle(on ? Color.white : Brand.tabText) }
            }
            .frame(width: 28, height: 28)
            .background(on ? Brand.accent : micHover && !dictation.unavailable ? ChatPalette.soft : .clear, in: Circle())
            .overlay {
                if on && !reduceMotion {
                    Circle().strokeBorder(Brand.accent.opacity(0.35), lineWidth: 2)
                        .scaleEffect(1 + dictation.level * 0.35).animation(.easeOut(duration: 0.12), value: dictation.level)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { micHover = $0 }
        .disabled(dictation.unavailable || dictation.transcribing)
        .help(dictation.unavailable ? tr("이 Mac에서는 이 언어를 기기 안에서 받아쓸 수 없어요") : dictation.transcribing ? tr("받아쓰는 중…") : on ? tr("받아쓰기 멈추기") : tr("음성으로 입력"))
        .accessibilityLabel(on ? tr("받아쓰기 멈추기") : tr("음성으로 입력"))
    }

    private var sendButton: some View {
        let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Only this conversation's answer can be stopped here; another one running just blocks sending.
        let elsewhere = chat.running && !busy
        let blocked = elsewhere || !state.chatConnected
        return Button {
            if busy { chat.cancel() } else { send() }
        } label: {
            let enabled = busy || (!empty && !blocked)
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(enabled ? Color.white : Brand.gray)
                .frame(width: 28, height: 28)
                .background(enabled ? Brand.accent : Brand.line, in: Circle())
        }
        .buttonStyle(.plain).disabled(!busy && (empty || blocked))
        .help(busy ? tr("응답 중단 (Esc, ⌘.)") : !state.chatConnected ? tr("AI를 먼저 연결해 주세요") : elsewhere ? tr("다른 대화의 응답이 끝나면 보낼 수 있어요") : tr("전송 (Enter)"))
        .accessibilityLabel(busy ? tr("응답 중단") : tr("전송"))
    }

    // MARK: 칩 (웹 검색, 첨부)

    /// 첨부 칩(CH-18): 옅은 바탕, 1pt 테두리, 둥글기 4, 높이 22
    private func attachmentChip(icon: String, text: String, help: String, item: ChatLibraryItem? = nil, remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            if let item {
                Button { previewItem = item } label: {
                    HStack(spacing: 5) {
                        ChatAttachmentThumb(url: library.store.url(for: item))
                        Text(text).font(Brand.font(.tag)).lineLimit(1)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Image(systemName: icon).font(.system(size: 10))
                Text(text).font(Brand.font(.tag)).lineLimit(1)
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    .buttonStyle(.plain).disabled(busy).help(tr("빼기")).accessibilityLabel(tr("\(text) 빼기"))
            }
        }
        .foregroundStyle(Brand.tabText)
        .padding(.horizontal, 7).frame(height: 22)
        .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
        .help(help)
    }

    private func chip(icon: String, text: String, help: String, remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Brand.font(.caption)).lineLimit(1)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    .buttonStyle(.plain).disabled(busy).help(tr("빼기")).accessibilityLabel(tr("\(text) 빼기"))
            }
        }
        .foregroundStyle(Brand.chipSelectedText)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Brand.chipSelectedFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.chipSelectedBorder, lineWidth: 1))
        .help(help)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 고정 목록에서 뺀 스킬도 현재 대화에 적용 중이면 해제할 수 있게 남긴다.
                ForEach(chat.skills.filter { chat.current.skillIDs.contains($0.id) && !chat.pinnedSkillIDs.contains($0.id) }) { skill in
                    chip(icon: skill.icon, text: skill.displayTitle, help: tr("적용 중인 스킬")) {
                        chat.current.skillIDs.removeAll { $0 == skill.id }
                    }
                }
                if !chat.current.scope.useActivity {
                    chip(icon: "diamond", text: tr("기록 안 씀"), help: tr("참고할 기록 메뉴에서 범위를 바꿀 수 있어요"))
                } else if !chat.current.scope.focus.isEmpty {
                    chip(icon: "diamond", text: ChatFocusButton.label(chat.current.scope, choices: chat.focusChoices), help: tr("범위 빼기")) {
                        chat.current.scope.focus = []
                    }
                }
                if chat.current.scope.useWeb {
                    chip(icon: "globe", text: tr("웹 검색"), help: tr("웹 검색 끄기")) { chat.current.scope.useWeb = false }
                }
                ForEach(chat.draftConnectors, id: \.self) { id in
                    let name = ConnectorEntry.all.first { $0.id == id }?.name ?? id
                    chip(icon: "puzzlepiece.extension", text: name, help: tr("이번 요청의 참고 자료")) {
                        chat.draftConnectors.removeAll { $0 == id }
                    }
                }
                if library.busy {
                    ProgressView().controlSize(.small)
                    Text(tr("소스를 추가하고 있어요")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: + 메뉴

    private var plusMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "square.and.arrow.up", title: tr("파일 업로드")) { showPlus = false; chat.uploadFiles() }
            MenuRow(icon: "archivebox", title: tr("결과물에서 선택")) { showPlus = false; DispatchQueue.main.async { showLibraryPicker = true } }
            MenuRow(icon: "folder.badge.plus", title: tr("원본 파일과 폴더 연결")) { showPlus = false; chat.connectFiles() }
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
            MenuRow(icon: "diamond", title: tr("참고할 기록")) { showPlus = false; DispatchQueue.main.async { showFocus = true } } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
            }
            MenuRow(icon: "globe", title: tr("웹 검색")) { chat.current.scope.useWeb.toggle() } trailing: {
                WebSwitch(on: chat.current.scope.useWeb)
            }
            MenuRow(icon: "puzzlepiece.extension", title: tr("커넥터")) { showConnectors = true } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
            }
            .popover(isPresented: $showConnectors, arrowEdge: .trailing) { connectorMenu }
        }
        .padding(6).frame(width: 190)
    }

    /// CH-31, CH-71: 커넥터 선택과 둘러보기
    private var connectorMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ConnectorEntry.all) { connector in
                        connectorRow(connector.name, connector.icon, connector.id == "github" ? githubBinding() : connectorBinding(connector.id))
                    }
                }
            }.frame(height: 260)
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
            MenuRow(icon: "square.grid.2x2", title: tr("커넥터 둘러보기")) { showConnectors = false; showPlus = false; onOpenConnectors() }
        }
        .padding(6).frame(width: 190)
    }

    private func connectorRow(_ title: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        MenuRow(icon: icon, title: title) { on.wrappedValue.toggle() } trailing: { WebSwitch(on: on.wrappedValue) }
    }

    // MARK: 스킬 칩 (CH-01, CH-33)

    private var skillChips: some View {
        // Pencil sits outside the scroll so overflowing chips never hide it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { skillRow; skillPencil }
            HStack(spacing: 6) { ScrollView(.horizontal, showsIndicators: false) { skillRow }; skillPencil }
        }
        .frame(height: 22)
    }

    private var skillRow: some View {
        HStack(spacing: 6) {
            ForEach(chat.pinnedSkills) { skill in
                let on = chat.current.skillIDs.contains(skill.id)
                Button {
                    if on { chat.current.skillIDs.removeAll { $0 == skill.id } } else { chat.current.skillIDs.append(skill.id) }
                } label: {
                    Text(skill.displayTitle).font(Brand.font(.tag)).lineLimit(1)
                        .foregroundStyle(on ? Brand.chipSelectedText : Brand.tabText)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(on ? Brand.chipSelectedFill : ChatPalette.soft, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Brand.chipSelectedBorder : Brand.line))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(busy).accessibilityLabel(skill.displayTitle).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var skillPencil: some View {
        Button { showSkillPins = true } label: {
            Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
                .frame(width: 22, height: 22).background(ChatPalette.soft, in: Circle())
        }
        .buttonStyle(.plain).disabled(busy).help(tr("표시할 스킬 편집")).accessibilityLabel(tr("표시할 스킬 편집"))
        .popover(isPresented: $showSkillPins, arrowEdge: .top) {
            PinnedSkillPicker(chat: chat) {
                showSkillPins = false
                state.customizeSection = .skills
                state.selectedTab = .connectors
            }
        }
    }

    // MARK: 연결과 모델 (CH-08)

    private var connectHost: String { URL(string: state.settings.chatEndpoint.url)?.host?.lowercased() ?? "" }
    private var connectLabel: String {
        return connectHost.contains("anthropic") ? "Claude API" : "API"
    }

    @ViewBuilder private func providerLogo(_ provider: String, claude: Bool = false) -> some View {
        if provider == "codex", let mark = Brand.openAIMark {
            Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color(hex: 0x4A3E37))
        } else if claude {
            SVGIcon(d: Brand.claudePath).fill(Color(hex: 0xD97757))
        } else {
            SVGIcon(d: RailIcon.link).stroke(Brand.tabText, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    @ViewBuilder private var connectionButton: some View {
        if state.settings.effectiveChatProvider == "codex" {
            HStack(spacing: 6) {
                providerLogo("codex").frame(width: 13, height: 13).accessibilityLabel("ChatGPT")
                Rectangle().fill(Brand.line).frame(width: 1, height: 10)
                ChatModelMenu(name: modelName, fontSize: 11, openSettings: openSettings)
            }.fixedSize()
        } else {
            providerMenuButton
        }
    }

    private var providerMenuButton: some View {
        Button { showConnect = true } label: {
            HStack(spacing: 6) {
                providerLogo(state.settings.effectiveChatProvider, claude: connectHost.contains("anthropic")).frame(width: 13, height: 13)
                Text(connectLabel).font(Brand.font(.caption, .medium)).foregroundStyle(Color(hex: 0x4A3E37))
                Rectangle().fill(Color(hex: 0xCFC8C1)).frame(width: 1, height: 10)
                Text(modelName).font(Brand.font(.caption)).foregroundStyle(Color(hex: 0x7A716B)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Brand.tabText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize().help(tr("연결 방식 바꾸기"))
        .popover(isPresented: $showConnect, arrowEdge: .top) { connectMenu }
    }

    /// 방식을 고르는 곳은 설정 AI 연결이라, 줄을 누르면 그 방식을 고른 채 설정으로 간다
    private var connectMenu: some View {
        let current = state.settings.effectiveChatProvider
        return VStack(alignment: .leading, spacing: 0) {
            connectRow(tr("ChatGPT 구독"), "codex", on: current == "codex")
            connectRow("API", "openai", on: current != "codex")
        }
        .padding(6).frame(width: 190)
    }

    private func connectRow(_ title: String, _ provider: String, on: Bool) -> some View {
        MenuRow(icon: nil, title: title) {
            showConnect = false
            state.settings.llmProvider = provider     // 설정의 연결 방식 메뉴와 같은 값
            state.settings.chatProvider = provider
            openSettings()
        } trailing: {
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.tabText) }
        }
    }

    /// An image attachment shows its picture; anything else, or an unreadable image, the doc icon.
    private struct ChatAttachmentThumb: View {
        let url: URL
        @State private var image: NSImage?
        var body: some View {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 2))
                } else {
                    Image(systemName: "doc").font(.system(size: 10))
                }
            }
            // Load once per file, not on every keystroke that redraws the composer.
            .task(id: url) {
                image = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased()) ? NSImage(contentsOf: url) : nil
            }
        }
    }

    /// + 메뉴 한 줄: 24 높이, 둥글기 6, 마우스를 올리면 rowHover
    fileprivate struct MenuRow<Trailing: View>: View {
        let icon: String?
        let title: String
        let action: () -> Void
        @ViewBuilder var trailing: Trailing
        @State private var hover = false

        init(icon: String?, title: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
            self.icon = icon; self.title = title; self.action = action; self.trailing = trailing()
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Brand.tabText).frame(width: 14) }
                    Text(title).font(Brand.font(.body)).foregroundStyle(Brand.text).lineLimit(1)
                    Spacer(minLength: 6)
                    trailing
                }
                .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity)
                .background(hover ? ChatPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
        }
    }

    /// 26×15 스위치 (그림만, 누르는 것은 줄 전체)
    private struct WebSwitch: View {
        let on: Bool
        var body: some View {
            Capsule().fill(on ? Brand.accent : ChatPalette.inputLine).frame(width: 26, height: 15)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 11, height: 11).padding(2) }
                .accessibilityLabel(on ? tr("웹 검색 켬") : tr("웹 검색 끔"))
        }
    }

    // MARK: 범위 아래 안내

    /// 범위를 좁혔을 때: 정리 전 기록은 아직 업무가 없어 빠진다
    private var tidyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text(tr("정리 전 최근 기록 \(pendingRecords)건은 아직 빠져요"))
            Button(action: tidyNow) { Text(tr("지금 정리")).underline().foregroundStyle(Brand.ink) }.buttonStyle(.plain)
        }
        .font(Brand.font(.tag)).foregroundStyle(Brand.gray)
    }

    /// Args: id는 대화에서 켜거나 끌 커넥터이다.
    /// Returns: 대화별 커넥터 선택 바인딩. 연결 안 된 커넥터를 켜면 커넥터 화면으로 간다.
    /// Raises: 없음.
    private func connectorBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { chat.current.scope.connectors.contains(id) }, set: { enabled in
            if enabled {
                guard (try? ConnectorAuth.isConnected(id)) == true else { showConnectors = false; showPlus = false; onOpenConnectors(); return }
                if !chat.current.scope.connectors.contains(id) { chat.current.scope.connectors.append(id) }
            } else { chat.current.scope.connectors.removeAll { $0 == id } }
        })
    }

    /// Args: 없음.
    /// Returns: GitHub 연결 상태를 확인한 뒤 변경하는 대화별 자료 바인딩.
    /// Raises: 없음. 미연결 상태에서는 커넥터 화면으로 간다.
    private func githubBinding() -> Binding<Bool> {
        Binding(get: { chat.current.scope.useGitHub }, set: { enabled in
            if enabled && (try? ConnectorAuth.isConnected("github")) != true { showConnectors = false; showPlus = false; onOpenConnectors(); return }
            chat.current.scope.useGitHub = enabled
        })
    }
}

extension ChatComposer.MenuRow where Trailing == EmptyView {
    init(icon: String?, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action) { EmptyView() }
    }
}

/// 칩을 폭 안에서 왼쪽부터 채우고 넘치면 다음 줄로 넘긴다
struct ChatChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], min(size.width, width), size.height))
            }
        }
        return rows
    }
}
