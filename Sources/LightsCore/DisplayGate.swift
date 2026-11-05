import Foundation

/// Decides when the floating light is redrawn. A light you pick by hand (a tapped bulb,
/// "Off") stays until a hook reports or what should be shown changes.
public struct DisplayGate: Sendable {
    private var shown: SessionState?? = .none
    private var isPickedByHand = false

    public init() {}

    public mutating func shouldShow(_ state: SessionState?, isReport: Bool) -> Bool {
        if case .some(let last) = shown, last == state, !(isReport && isPickedByHand) {
            return false
        }
        shown = .some(state)
        isPickedByHand = false
        return true
    }

    public mutating func pickedByHand() {
        isPickedByHand = true
    }
}
