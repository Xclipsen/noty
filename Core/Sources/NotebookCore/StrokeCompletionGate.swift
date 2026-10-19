/// PencilKit finishes its pressure/path data after the tool-end callback.
/// Never replace live input before both lift and final drawing are observed.
public struct StrokeCompletionGate: Sendable {
    public private(set) var lifted = false
    public private(set) var nativeEnded = false
    public private(set) var finalized = false
    public init() {}
    public mutating func lift() { lifted = true }
    public mutating func endNative() { nativeEnded = true }
    public mutating func drawingChanged() { if nativeEnded { finalized = true } }
    public var canCommit: Bool { lifted && nativeEnded && finalized }
}
