import SwiftUI
import SillogCore

struct ConnectorEntry: Identifiable {
    let id: String
    let name: String
    let summary: String
    let description: String
    let examples: [String]

    var icon: String {
        switch id {
        case "slack", "discord": "bubble.left.and.bubble.right"
        case "drive": "externaldrive"
        case "github", "lovable": "chevron.left.forwardslash.chevron.right"
        case "notion": "doc.text"
        case "figma", "canva": "paintbrush"
        case "higgsfield": "film"
        default: "puzzlepiece.extension"
        }
    }

    static let all: [ConnectorEntry] = [
        .init(id: "drive", name: "Google Drive", summary: tr("고른 파일 검색과 읽기"),
              description: tr("Drive에서 직접 고른 파일만 찾고 읽어요. 파일을 만들거나 수정하지 않아요."),
              examples: [tr("최근 작성한 기획서를 찾아 핵심 결정을 요약해 줘."), tr("고른 Drive 자료를 바탕으로 발표 개요를 만들어 줘.")]),
        .init(id: "github", name: "GitHub", summary: tr("저장소, 코드와 PR 읽기"),
              description: tr("접근 권한이 있는 저장소의 코드와 PR을 읽어요. 저장소를 변경하지 않아요."),
              examples: [tr("내가 작업한 저장소의 구조와 주요 기능을 설명해 줘."), tr("최근 PR을 바탕으로 프로젝트 진행 상황을 정리해 줘.")]),
        .init(id: "notion", name: "Notion", summary: tr("페이지 검색과 읽기"),
              description: tr("승인한 Notion 자료를 검색하고 페이지 내용을 읽어요. SILLOG에서는 검색과 읽기만 실행해요."),
              examples: [tr("최근 회의록에서 결정 사항과 다음 할 일을 찾아 줘."), tr("Notion에 정리한 자료를 바탕으로 계획을 세워줘.")]),
        .init(id: "figma", name: "Figma", summary: tr("디자인 파일과 화면 텍스트"),
              description: tr("지정한 폴더에서 디자인 파일을 찾고, 화면과 레이어 이름 및 텍스트를 읽어요."),
              examples: [tr("설정 화면 디자인을 찾아 표시된 문구를 알려 줘.")]),
        .init(id: "slack", name: "Slack", summary: tr("메시지 검색과 읽기"),
              description: tr("연결한 사용자가 검색할 수 있는 메시지의 본문과 링크를 읽어요."),
              examples: [tr("이번 주 디자인 회의 메시지에서 결정 사항을 찾아 줘.")]),
        .init(id: "discord", name: "Discord", summary: tr("지정한 채널의 메시지"),
              description: tr("봇이 읽을 수 있는 지정 채널의 최근 100개 메시지를 검색하고 원문을 읽어요."),
              examples: [tr("이 채널의 최근 메시지에서 다음 일정이 나온 부분을 찾아 줘.")]),
        .init(id: "higgsfield", name: "Higgsfield", summary: tr("생성 기록과 결과 읽기"),
              description: tr("계정의 생성 기록과 결과를 읽어요. 새 이미지나 영상을 생성하지 않아요. 서비스에서 유료 구독을 요구할 수 있어요."),
              examples: [tr("최근 Higgsfield 생성 기록을 찾아 결과를 정리해 줘.")]),
        .init(id: "canva", name: "Canva", summary: tr("디자인 검색과 읽기"),
              description: tr("접근할 수 있는 디자인을 찾아 페이지와 글자, 댓글을 읽어요. 디자인을 만들거나 수정하지 않아요."),
              examples: [tr("발표 디자인을 찾아 제목과 페이지 수를 정리해 줘.")]),
        .init(id: "lovable", name: "Lovable", summary: tr("프로젝트 검색과 코드 읽기"),
              description: tr("승인한 워크스페이스에서 프로젝트를 찾고 설명과 코드 파일을 읽어요. 프로젝트를 수정하거나 배포하지 않아요."),
              examples: [tr("워크스페이스에서 랜딩 페이지 프로젝트를 찾아 진행 상황을 알려 줘.")])
    ]
}

/// 맞춤 설정의 커넥터 구역: 둘러보기 목록(검색, 설치됨 구역)과 커넥터 상세.
/// 고른 커넥터와 연결 상태는 왼쪽 목록(CustomizeView)과 나눠 쓰므로 바인딩으로 받는다
struct ConnectorCatalogView: View {
    var onUseInChat: (String, String) -> Void
    @Binding var selectedID: String?
    @Binding var connected: Set<String>

    @State private var query = ""
    @State private var connectedOnly = false
    @State private var externalConnector: ConnectorEntry?
    @State private var externalCredential = ""
    @State private var externalResource = ""
    @State private var externalError: String?
    @State private var connecting = false
    @State private var verificationCode: String?
    @State private var notice: String?
    @State private var showNotice = false

    private static let soft = Brand.paper

    private var githubInstallURL: URL? { try? ConnectorAuth.githubInstallURL() }
    private var selected: ConnectorEntry? { ConnectorEntry.all.first { $0.id == selectedID } }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var filtered: [ConnectorEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectorEntry.all.filter { connector in
            (!connectedOnly || connected.contains(connector.id))
                && (text.isEmpty || connector.name.localizedCaseInsensitiveContains(text) || connector.summary.localizedCaseInsensitiveContains(text))
        }
    }

    var body: some View {
        Group { if let selected { detail(selected) } else { catalog } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.white)
            .sheet(item: $externalConnector) { externalConnectSheet($0) }
            .alert(tr("커넥터 연결"), isPresented: $showNotice) {
                Button(tr("확인"), role: .cancel) {}
            } message: { Text(notice ?? "") }
            .task { await refresh() }
    }

    // MARK: 목록 (CH-13, 70, 72, 73)

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CatalogHeader(title: tr("커넥터"), description: tr("외부 서비스를 연결해 채팅에서 내 자료를 활용해요."), query: $query) {
                    EmptyView()
                }
                HStack(spacing: 6) {
                    filterPill(tr("전체"), onlyConnected: false)
                    filterPill(tr("연결됨"), onlyConnected: true)
                }
                if filtered.isEmpty {
                    Text(searching ? tr("맞는 커넥터가 없어요.") : tr("연결한 커넥터가 없어요."))
                        .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                } else if searching {
                    section(tr("검색 결과"), filtered)
                } else {
                    let installed = filtered.filter { connected.contains($0.id) }
                    let available = filtered.filter { !connected.contains($0.id) }
                    if !installed.isEmpty { section(tr("연결한 커넥터"), installed) }
                    if !available.isEmpty { section(tr("둘러보기"), available) }
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 26)
            .frame(maxWidth: 984, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func filterPill(_ title: String, onlyConnected: Bool) -> some View {
        let on = connectedOnly == onlyConnected
        return Button { connectedOnly = onlyConnected } label: {
            Text(title).font(Brand.font(.caption, .medium)).foregroundStyle(on ? Brand.ink : Brand.gray)
                .padding(.horizontal, 12).frame(height: 27)
                .background(on ? Brand.badgeFill : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : Brand.line))
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func section(_ title: String, _ items: [ConnectorEntry]) -> some View {
        CatalogSection(title: title, columns: 2) {
            ForEach(items) { connector in
                CatalogRow(title: connector.name, subtitle: connector.summary, large: true, open: { selectedID = connector.id }) {
                    ConnectorLogo(connector: connector, size: 44)
                } actions: {
                    if connected.contains(connector.id) {
                        moreMenu(connector, showsChatAction: true)
                    } else {
                        Button {
                            selectedID = connector.id
                            install(connector)
                        } label: {
                            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.tabText)
                                .frame(width: 30, height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(connecting)
                        .help(tr("\(connector.name) 연결")).accessibilityLabel(tr("\(connector.name) 연결"))
                    }
                }
            }
        }
    }

    // MARK: 상세 (CH-25, 26, 37, 62)

    private func detail(_ connector: ConnectorEntry) -> some View {
        let on = connected.contains(connector.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { selectedID = nil } label: { Text(tr("커넥터")).font(Brand.font(.body)).foregroundStyle(Brand.gray) }.buttonStyle(.plain)
                    Text("›").font(Brand.font(.body)).foregroundStyle(Brand.gray)
                    Text(connector.name).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                }
                .padding(.horizontal, 32).padding(.top, 19)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ConnectorLogo(connector: connector, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connector.name).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
                            Text(connector.summary).font(Brand.font(.body)).foregroundStyle(Brand.gray)
                        }
                        Spacer(minLength: 6)
                        if on { moreMenu(connector) }
                        mainButton(connector, on: on)
                    }.padding(.top, 22)
                    examplePanel(connector, on: on).padding(.top, 15)
                    Text(connector.description).font(Brand.font(.body)).foregroundStyle(Brand.tabText).padding(.top, 18)
                    if ["drive", "slack", "notion", "higgsfield", "lovable", "canva"].contains(connector.id) {
                        Text(tr("연결을 누르면 브라우저에서 로그인하고 권한을 승인해요. 키를 직접 발급할 필요가 없어요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 10)
                    }
                    if connector.id == "notion" || connector.id == "higgsfield" {
                        Text(tr("서비스의 승인 화면에는 편집·생성 권한이 함께 포함될 수 있어요. SILLOG은 검색·읽기 도구만 허용해요. 승인할 권한은 브라우저에서 확인해 주세요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 10)
                    }
                    if on {
                        HStack(spacing: 8) {
                            if connector.id == "github", let url = githubInstallURL {
                                Button(tr("Repository 선택")) { NSWorkspace.shared.open(url) }.buttonStyle(BrandButtonStyle(kind: .secondary))
                            }
                            if connector.id == "drive" {
                                Button(tr("Drive 파일 고르기")) { pickDriveFiles() }
                                    .buttonStyle(BrandButtonStyle(kind: .secondary)).disabled(connecting)
                            }
                            Button(tr("검색·읽기 확인")) { checkConnection(connector) }
                                .buttonStyle(BrandButtonStyle(kind: .secondary)).disabled(connecting)
                        }.padding(.top, 16)
                    }
                    if let verificationCode, connector.id == "github" {
                        Text(tr("GitHub 승인 코드: \(verificationCode)"))
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(Brand.ink).textSelection(.enabled)
                            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(Self.soft, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 16)
                    }
                    Text(tr("정보")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink).padding(.top, 24).padding(.bottom, 8)
                    Rectangle().fill(Brand.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow(tr("SILLOG에서 실행"), tr("검색·읽기만 해요"))
                        infoRow(tr("연결 정보"), tr("이 Mac의 키체인에 보관해요"))
                        infoRow(tr("제공"), connector.id == "drive" ? "Google" : connector.name)
                    }.padding(.top, 11)
                    Text(tr("질문과 조회한 자료는 연결한 AI로 전송돼요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.top, 22)
                }
                .padding(.horizontal, 32).padding(.bottom, 32)
                .frame(maxWidth: 732, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label).font(Brand.font(.body)).foregroundStyle(Brand.gray).frame(width: 110, alignment: .leading)
            Text(value).font(Brand.font(.body)).foregroundStyle(Brand.ink)
        }
    }

    /// 연결 상태에 맞춰 연결 화면이나 채팅을 연다.
    private func mainButton(_ connector: ConnectorEntry, on: Bool) -> some View {
        Button { if on { onUseInChat(connector.id, connector.examples[0]) } else { install(connector) } } label: {
            Text(on ? tr("채팅에서 사용해 보기") : connecting ? tr("연결 중…") : tr("커넥터 연결"))
                .font(Brand.font(.body, .medium)).foregroundStyle(.white).fixedSize()
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Brand.accent))
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(connecting)
    }

    private func moreMenu(_ connector: ConnectorEntry, showsChatAction: Bool = false) -> some View {
        Menu {
            if showsChatAction {
                Button(tr("채팅에서 사용해 보기")) { onUseInChat(connector.id, connector.examples[0]) }
            }
            if connector.id == "github", let url = githubInstallURL {
                Button(tr("Repository 선택")) { NSWorkspace.shared.open(url) }
            }
            Button(tr("검색·읽기 확인")) { checkConnection(connector) }
            Button(tr("다시 연결")) { selectedID = connector.id; install(connector) }
            Button(tr("연결 해제"), role: .destructive) { disconnect(connector.id) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.tabText)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(connecting)
        .accessibilityLabel(tr("\(connector.name) 작업"))
    }

    /// 예시 질문 판: 새 대화 첫 화면과 같은 바탕에 흰 반투명 줄. 설치 전에 누르면 설치를 시작한다
    private func examplePanel(_ connector: ConnectorEntry, on: Bool) -> some View {
        VStack(spacing: 12) {
            ForEach(connector.examples, id: \.self) { example in
                Button { if on { onUseInChat(connector.id, example) } else { install(connector) } } label: {
                    HStack(spacing: 12) {
                        ConnectorLogo(connector: connector, size: 16, boxed: false)
                        Text(connector.name).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                        Text(example).font(Brand.font(.body)).foregroundStyle(Brand.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Circle().fill(Brand.pillFill))
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.78)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 22).frame(maxWidth: .infinity, minHeight: 106)
        .background(ChatStartBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func externalConnectSheet(_ connector: ConnectorEntry) -> some View {
        let resourceLabel: String?
        let credentialLabel: String
        let steps: [String]
        let guide: (title: String, url: URL)?
        switch ExternalReadConnector(rawValue: connector.id) {
        case .figma:
            (resourceLabel, credentialLabel) = (tr("폴더 ID"), tr("개인 액세스 토큰"))
            steps = [tr("Figma 왼쪽 위 계정 메뉴에서 설정 → 보안 탭을 열고, ‘개인 액세스 토큰’의 ‘새 토큰 생성’을 누르세요."),
                     tr("권한은 file_content:read와 folders:read 두 가지만 읽기로 켜고 토큰을 만드세요. 토큰은 만들 때 한 번만 보이니 바로 복사하세요."),
                     tr("SILLOG이 읽을 Figma 폴더를 브라우저에서 열고, 주소에서 folder/ 또는 project/ 뒤의 숫자를 폴더 ID 칸에 넣으세요.")]
            guide = (tr("Figma 토큰 안내 열기"), URL(string: "https://help.figma.com/hc/en-us/articles/8085703771159-Manage-personal-access-tokens")!)
        case .discord:
            (resourceLabel, credentialLabel) = (tr("채널 ID"), tr("봇 토큰"))
            steps = [tr("Discord 개발자 포털에서 New Application을 눌러 앱을 만드세요."),
                     tr("Bot 메뉴에서 Reset Token을 눌러 봇 토큰을 복사하고, 같은 화면의 Message Content Intent를 켜세요."),
                     tr("OAuth2 → URL Generator에서 bot을 고르고 View Channels와 Read Message History 권한만 체크한 뒤, 만들어진 주소로 봇을 서버에 초대하세요."),
                     tr("Discord 사용자 설정 → 고급에서 개발자 모드를 켜고, 읽을 채널을 오른쪽 클릭해 ‘채널 ID 복사’를 누르세요.")]
            guide = (tr("Discord 개발자 포털 열기"), URL(string: "https://discord.com/developers/applications")!)
        default:
            (resourceLabel, credentialLabel) = (nil, tr("토큰 또는 API 키"))
            steps = [tr("이 서비스는 브라우저 로그인으로 연결해 주세요.")]
            guide = nil
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(tr("\(connector.name) 연결")).font(Brand.font(.screenTitle))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").font(Brand.font(.caption, .medium)).foregroundStyle(Brand.gray)
                        Text(step).font(Brand.font(.body)).foregroundStyle(Brand.tabText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let guide { Link(guide.title, destination: guide.url).font(Brand.font(.body)) }
            if let resourceLabel { TextField(resourceLabel, text: $externalResource) }
            SecureField(credentialLabel, text: $externalCredential)
            Text(tr("연결을 확인한 뒤 이 Mac의 키체인에 저장해요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
            if let externalError { Text(externalError).font(Brand.font(.body)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(tr("취소")) { externalConnector = nil; externalCredential = "" }.keyboardShortcut(.cancelAction).disabled(connecting)
                Button(connecting ? tr("확인 중…") : tr("연결")) { connectExternal(connector) }.keyboardShortcut(.defaultAction)
                    .disabled(connecting || externalCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (resourceLabel != nil && externalResource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(connecting)
    }

    private func connectExternal(_ connector: ConnectorEntry) {
        connecting = true
        externalError = nil
        Task {
            defer { connecting = false }
            do {
                if let external = ExternalReadConnector(rawValue: connector.id) {
                    try await ConnectorAuth.connectExternal(external, token: externalCredential, resource: externalResource)
                }
                connected.insert(connector.id)
                externalCredential = ""
                externalConnector = nil
            } catch {
                externalError = error.localizedDescription
            }
        }
    }

    /// Args: connector is the service to install.
    /// Returns: nothing. Starts the provider's sign-in.
    /// Raises: none. Errors are shown on screen.
    private func install(_ connector: ConnectorEntry) {
        if let remote = RemoteReadConnector(rawValue: connector.id) {
            connecting = true
            Task {
                defer { connecting = false }
                do {
                    try await ConnectorAuth.connectRemote(remote)
                    connected.insert(connector.id)
                    notify(tr("\(connector.name) 계정을 연결했어요. ‘검색·읽기 확인’으로 실제 자료를 읽을 수 있는지 검사할 수 있어요."))
                } catch { notify(error.localizedDescription) }
            }
            return
        }
        if connector.id == "slack" {
            connecting = true
            Task {
                defer { connecting = false }
                do {
                    try await ConnectorAuth.connectSlack()
                    connected.insert(connector.id)
                } catch { notify(error.localizedDescription) }
            }
            return
        }
        if ExternalReadConnector(rawValue: connector.id) != nil {
            prepareCredentials(connector)
            return
        }
        if connector.id == "drive" {
            connectDrive()
            return
        }
        do {
            guard try ConnectorAuth.isAvailable(connector.id) else {
                notify(tr("이 빌드에는 \(connector.name) 연결 정보가 아직 없습니다. 앱 제공자가 OAuth 앱을 등록해야 사용할 수 있습니다."))
                return
            }
        } catch { notify(error.localizedDescription); return }
        connecting = true
        Task {
            do {
                if connector.id == "github" {
                    let client = try ConnectorAuth.configuration("github-client", environment: "GITHUB_CLIENT_ID")
                    try await ConnectorAuth.connectGitHub(clientID: client) { verificationCode = $0 }
                    // A GitHub App token sees no repositories until the app is installed on some.
                    if let url = githubInstallURL {
                        NSWorkspace.shared.open(url)
                        notify(tr("GitHub 계정을 연결했어요. 브라우저에서 SILLOG이 읽을 Repository를 선택해 주세요. 나중에 바꾸려면 ‘Repository 선택’을 누르세요."))
                    }
                }
                connected.insert(connector.id)
            } catch { notify(error.localizedDescription) }
            verificationCode = nil
            connecting = false
        }
    }

    private func prepareCredentials(_ connector: ConnectorEntry) {
        externalCredential = ""
        externalResource = (try? ConnectorAuth.resource(connector.id)) ?? ""
        externalError = nil
        externalConnector = connector
    }

    private func checkConnection(_ connector: ConnectorEntry) {
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let tools = ChatTools(db: try SillogDatabase.inMemory(), scope: ChatScope(),
                                      connectorToken: { try await ConnectorAuth.accessToken($0) },
                                      connectorResource: { try ConnectorAuth.resource($0) },
                                      remoteConnectors: ConnectorAuth.remoteIDs().union(RemoteReadConnector(rawValue: connector.id).map { [$0.rawValue] } ?? []))
                let read = try await tools.checkConnector(connector.id)
                let verified = connector.id == "github" ? tr("저장소 검색과 PR 목록 조회") : connector.summary
                notify(read ? tr("\(connector.name)에서 \(verified) 응답을 확인했어요.")
                       : tr("\(connector.name) 검색 응답을 받았어요. 읽을 내용은 확인되지 않았어요."))
            } catch {
                if error is ConnectorReconnectError { connected.remove(connector.id) }
                notify(tr("\(connector.name) 검사 실패 · \(error.localizedDescription)"))
            }
        }
    }

    /// Args: none.
    /// Returns: nothing. Signs in to Google Drive, then opens the file picker.
    /// Raises: none. OAuth errors are shown on screen.
    private func connectDrive() {
        do {
            guard try ConnectorAuth.isAvailable("drive") else {
                notify(tr("이 빌드에는 Google 연결 정보가 아직 없습니다. 앱 제공자가 OAuth 앱을 등록해야 사용할 수 있습니다."))
                return
            }
        } catch { notify(error.localizedDescription); return }
        connecting = true
        Task {
            do {
                let client = try ConnectorAuth.configuration("google-client", environment: "GOOGLE_CLIENT_ID")
                try await ConnectorAuth.connectGoogle(["drive"], clientID: client)
                connected.insert("drive")
                connecting = false
                pickDriveFiles()
            } catch { notify(error.localizedDescription); connecting = false }
        }
    }

    /// Args: none.
    /// Returns: nothing. Opens Google Picker in the browser; only picked files are readable with drive.file.
    /// Raises: none. Errors are shown on screen.
    private func pickDriveFiles() {
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let count = try await ConnectorAuth.pickDriveFiles()
                if count > 0 { notify(tr("Drive 파일 \(count)개를 SILLOG이 읽을 수 있어요. 더 추가하려면 ‘Drive 파일 고르기’를 누르세요.")) }
            } catch {
                if error is ConnectorReconnectError { connected.remove("drive") }
                notify(error.localizedDescription)
            }
        }
    }

    /// Args: id는 연결을 해제할 서비스이다.
    /// Returns: 없음. 저장된 OAuth 토큰을 제거한다.
    /// Raises: 없음. Keychain 오류는 화면에 표시한다.
    private func disconnect(_ id: String) {
        do { try ConnectorAuth.disconnect(id); connected.remove(id) }
        catch { notify(error.localizedDescription) }
    }

    /// Args: none.
    /// Returns: nothing. Rereads which connectors have a saved account.
    /// Raises: none. A Keychain error is shown on screen.
    private func refresh() async {
        let ids = ConnectorEntry.all.map(\.id)
        // Off the main thread: a Keychain prompt would freeze the app while it waits.
        do { connected = try await Task.detached { Set(try ids.filter { try ConnectorAuth.isConnected($0) }) }.value }
        catch { notify(error.localizedDescription) }
    }

    /// Args: message는 사용자에게 보여줄 연결 상태나 오류이다.
    /// Returns: 없음. 알림을 표시한다.
    /// Raises: 없음.
    private func notify(_ message: String) { notice = message; showNotice = true }
}


/// 서비스가 배포한 이미지의 색상과 비율을 유지한 채 SILLOG의 타일에 배치한다.
struct ConnectorLogo: View {
    let connector: ConnectorEntry
    var size: CGFloat = 34
    var boxed = true

    @MainActor private static let images: [String: NSImage] = {
        Dictionary(uniqueKeysWithValues: ConnectorEntry.all.compactMap { entry in
            let url = Bundle.main.url(forResource: entry.id, withExtension: "png", subdirectory: "ConnectorIcons")
                ?? Bundle.module.url(forResource: entry.id, withExtension: "png", subdirectory: "ConnectorIcons")
            guard let url, let image = NSImage(contentsOf: url) else { return nil }
            return (entry.id, image)
        })
    }()

    var body: some View {
        let corner = size * 0.22
        let mark = boxed ? size * 0.64 : size
        Group {
            if let image = Self.images[connector.id] { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: connector.icon).font(.system(size: size * 0.42)).foregroundStyle(Brand.tabText) }
        }
        .frame(width: mark, height: mark)
        .frame(width: size, height: size)
        .background(boxed ? Brand.paper : .clear, in: RoundedRectangle(cornerRadius: corner))
        .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(boxed ? Brand.line : .clear))
        .accessibilityHidden(true)
    }
}
