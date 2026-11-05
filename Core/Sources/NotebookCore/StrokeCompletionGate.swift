/// PencilKit finishes its pressure/path data after the tool-end callback.
/// Never replace live input before both lift and final drawing are observed.
public struct StrokeCompletionGate: Sendable {
    public private(set) var lifted = false
    public private(set) var nativeEnded = false
    public private(set) var finalized = false
    /// A drawing change arrived at all (also before the tool-end callback).
    public private(set) var drawingSeen = false
    public init() {}
    public mutating func lift() { lifted = true }
    public mutating func endNative() { nativeEnded = true }
    public mutating func drawingChanged() { drawingSeen = true; if nativeEnded { finalized = true } }
    public var canCommit: Bool { lifted && nativeEnded && finalized }
    /// Lifted and ended, but PencilKit reported its drawing only before the
    /// tool-end callback: no further change may come. The held result is
    /// committed after a short grace period instead of waiting for the next
    /// touch, so a tool change, undo or closing right after the lift finds it
    /// already in the model.
    public var awaitsFinalDrawing: Bool { lifted && nativeEnded && drawingSeen && !finalized }
}
