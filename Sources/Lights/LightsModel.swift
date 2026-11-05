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
    private var gate = DisplayGate()

    var displayed: SessionState? { store.displayed(following: following) }
    var trackedTabs: Set<String> { store.tabs }

    func receive(_ signal: Signal, tab: String, session: String?) {
        store.apply(signal, tab: tab, session: session)
        publish(isReport: true)
    }

    func follow(_ target: Follow) {
        guard target != following else { return }
        following = target
        publish()
    }

    /// Runs every couple of seconds with what the terminal tabs and Claude Code are doing.
    func update(_ activity: TabActivity, statuses: [ClaudeStatus]) {
        store.retain(liveTabs: activity.live)
        store.reconcile(with: activity, statuses: statuses)
        publish()
    }

    /// A tapped bulb or "Off": shown until the next report or change.
    func showByHand(_ light: Light?) {
        gate.pickedByHand()
        post(light)
    }

    private func publish(isReport: Bool = false) {
        let now = displayed
        guard gate.shouldShow(now, isReport: isReport) else { return }
        post(now?.light)
    }

    private func post(_ light: Light?) {
        NotificationCenter.default.post(
            name: .lightsDisplayChange, object: nil,
            userInfo: ["light": light?.rawValue ?? "off"]
        )
    }
}
