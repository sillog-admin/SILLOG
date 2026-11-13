import Foundation

/// View-menu text zoom: the window's text sizes are multiplied by one of these steps.
public enum TextScale {
    public static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5]

    /// Args: current is the scale in use, delta is +1 to zoom in or -1 to zoom out.
    /// Returns: the nearest step past current in that direction, or the end step when there is none.
    public static func step(_ current: Double, by delta: Int) -> Double {
        // A small margin so 1.15 read back from JSON still counts as the 1.15 step.
        delta > 0 ? steps.first { $0 > current + 0.001 } ?? steps[steps.count - 1]
                  : steps.last { $0 < current - 0.001 } ?? steps[0]
    }

    /// Args: value is a saved scale.
    /// Returns: value kept within the smallest and largest step.
    public static func clamp(_ value: Double) -> Double {
        min(max(value, steps[0]), steps[steps.count - 1])
    }
}
