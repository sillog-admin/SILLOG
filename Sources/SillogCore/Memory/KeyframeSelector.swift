import Foundation

/// 배치의 행들에서 멀티모달로 보낼 대표 화면을 고른다 (LLM 없음).
///   - 같은 앱·창 제목·주소이고 차이 해시 거리가 가까운 사진은 같은 화면으로 묶는다 (스크롤로 내용이 바뀌면 다른 화면)
///   - 묶음의 머문 시간 = 사진이 속한 행의 체류 / 그 행의 사진 수 의 합
///   - 대표 = 묶음에서 시간상 가운데 사진
///   - 머문 시간 minSeconds 이상, 내용 없는 화면(잠금·시스템·Sillog·빈 탭·로그인) 제외. 이건 이미지 예산 규칙이지 업무 기준이 아니다
public enum KeyframeSelector {
    public struct Shot: Equatable, Sendable {
        public var observationId: Int64
        public var ts: Double
        public var path: String
        public var hash: UInt64
        public init(observationId: Int64, ts: Double, path: String, hash: UInt64) {
            self.observationId = observationId; self.ts = ts; self.path = path; self.hash = hash
        }
    }

    public struct Group: Equatable, Sendable {
        public var appBundle: String
        public var appName: String
        public var title: String?
        public var uri: String?
        public var shots: [Shot]
        public var seconds: Double
        /// 이 화면을 덮는 행 번호와 관측 id
        public var rows: [Int]
        public var observationIds: [Int64]
        public var start: Double
        public var end: Double
        public var representative: Shot { shots.sorted { $0.ts < $1.ts }[shots.count / 2] }

        public init(appBundle: String, appName: String, title: String?, uri: String?, shots: [Shot], seconds: Double,
                    rows: [Int], observationIds: [Int64], start: Double, end: Double) {
            self.appBundle = appBundle; self.appName = appName; self.title = title; self.uri = uri; self.shots = shots
            self.seconds = seconds; self.rows = rows; self.observationIds = observationIds; self.start = start; self.end = end
        }
    }

    public static let sameScreenDistance = 8

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// shots: 관측 id → 사진. 돌려주는 것: 보낼 만한 묶음 전부 (머문 시간 긴 순). 호출 상한은 호출자가 자른다
    public static func select(rows: [ActivityRow], shots: [Int64: Shot], minSeconds: Double = 5) -> [Group] {
        var groups: [Group] = []
        for row in rows.sorted(by: { ($0.start, $0.row) < ($1.start, $1.row) }) {
            guard !row.isChat, !EventStore.contentlessBundles.contains(row.appBundle), !TransientPages.isTransient(url: row.uri, title: row.title) else { continue }
            let rowShots = row.observationIds.compactMap { shots[$0] }.sorted { $0.ts < $1.ts }
            guard !rowShots.isEmpty else { continue }
            let share = Double(row.dwell) / Double(rowShots.count)
            var touched: [Int] = []                          // 이 행이 닿은 묶음 (시간순)
            var groupOfShot: [Int64: Int] = [:]
            for shot in rowShots {
                let index: Int
                if let found = groups.firstIndex(where: { $0.appBundle == row.appBundle && $0.title == row.title && $0.uri == row.uri
                                                        && distance($0.shots[0].hash, shot.hash) <= sameScreenDistance }) {
                    index = found
                    groups[index].shots.append(shot)
                    groups[index].start = min(groups[index].start, shot.ts)
                } else {
                    groups.append(Group(appBundle: row.appBundle, appName: row.app, title: row.title, uri: row.uri, shots: [shot], seconds: 0,
                                        rows: [], observationIds: [], start: shot.ts, end: shot.ts))
                    index = groups.count - 1
                }
                groups[index].seconds += share
                groupOfShot[shot.observationId] = index
                if touched.last != index { touched.append(index) }
            }
            // 행의 관측을 묶음에 나눠 준다: 사진이 있는 관측은 그 묶음, 없는 관측은 바로 앞 사진의 묶음 (앞이 없으면 첫 묶음)
            var current = touched[0]
            for id in row.observationIds {
                if let index = groupOfShot[id] { current = index }
                groups[current].observationIds.append(id)
            }
            for index in Set(touched) {
                if groups[index].rows.last != row.row { groups[index].rows.append(row.row) }
                groups[index].end = max(groups[index].end, row.end)
                groups[index].start = min(groups[index].start, row.start)
            }
        }
        return groups.filter { $0.seconds >= minSeconds }.sorted { ($0.seconds, -$0.start) > ($1.seconds, -$1.start) }
    }
}
