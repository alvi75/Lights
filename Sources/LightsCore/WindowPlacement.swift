import CoreGraphics
import Foundation

/// Where the user left the light: which display, and how far in from its top-right corner.
public struct SavedPlacement: Codable, Equatable {
    public let display: String
    public let fromRight: CGFloat
    public let fromTop: CGFloat
}

/// One connected display, in global window coordinates.
public struct DisplayArea: Equatable {
    public let id: String
    public let frame: CGRect
    public let visible: CGRect

    public init(id: String, frame: CGRect, visible: CGRect) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

public enum WindowPlacement {
    static let margin: CGFloat = 24

    /// The spot to remember, measured against the display holding most of the window.
    public static func save(frame: CGRect, displays: [DisplayArea]) -> SavedPlacement? {
        guard let display = holder(of: frame, in: displays) else { return nil }
        return SavedPlacement(display: display.id,
                              fromRight: display.frame.maxX - frame.maxX,
                              fromTop: display.frame.maxY - frame.maxY)
    }

    /// Where the window belongs right now. The saved display wins whenever it is connected,
    /// so a monitor that drops out during sleep gets the light back when it returns.
    /// `displays` lists the main display first.
    public static func frame(for size: CGSize, saved: SavedPlacement?, current: CGRect?,
                             displays: [DisplayArea]) -> CGRect? {
        if let saved, let display = displays.first(where: { $0.id == saved.display }) {
            let spot = CGRect(x: display.frame.maxX - saved.fromRight - size.width,
                              y: display.frame.maxY - saved.fromTop - size.height,
                              width: size.width, height: size.height)
            return clamp(spot, into: display.visible)
        }
        if let current, let display = holder(of: current, in: displays) {
            return clamp(CGRect(origin: current.origin, size: size), into: display.visible)
        }
        guard let main = displays.first?.visible else { return nil }
        return CGRect(x: main.maxX - size.width - margin, y: main.maxY - size.height - margin,
                      width: size.width, height: size.height)
    }

    static func holder(of frame: CGRect, in displays: [DisplayArea]) -> DisplayArea? {
        let shares = displays.map { ($0, area($0.frame.intersection(frame))) }
        guard let best = shares.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    static func clamp(_ rect: CGRect, into area: CGRect) -> CGRect {
        let x = max(area.minX, min(rect.minX, area.maxX - rect.width))
        let y = max(area.minY, min(rect.minY, area.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}
