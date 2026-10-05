import Foundation
import LightsCore

extension Notification.Name {
    static let lightsDisplayChange = Notification.Name("LightsDisplayChange")
}

/// Holds every session's state and decides what the light shows.
@MainActor
final class LightsModel {
    static let shared = LightsModel()

    private var store = SessionStore()
    private(set) var following: Follow?
    private var published: SessionState??

    var displayed: SessionState? { store.displayed(following: following) }
    var trackedTabs: Set<String> { store.tabs }

    func receive(_ signal: Signal, tab: String) {
        store.apply(signal, tab: tab)
        publish()
    }

    func follow(_ target: Follow) {
        guard target != following else { return }
        following = target
        publish()
    }

    func retain(liveTabs: Set<String>) {
        store.retain(liveTabs: liveTabs)
        publish()
    }

    private func publish() {
        let now = displayed
        if case .some(let last) = published, last == now { return }
        published = .some(now)
        NotificationCenter.default.post(
            name: .lightsDisplayChange, object: nil,
            userInfo: ["light": now?.light.rawValue ?? "off"]
        )
    }
}
