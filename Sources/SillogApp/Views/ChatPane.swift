import Foundation

/// 채팅 탭 본문이 지금 무엇을 보여 주는지
enum ChatPane: Equatable {
    case chat                 // 지금 대화 (messages 가 비면 새 대화 화면)
    case projects             // CH-49, 50
    case project(String)      // CH-51~57, ChatProject.id
    case results              // CH-45
}
