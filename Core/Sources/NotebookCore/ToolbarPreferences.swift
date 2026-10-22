import Foundation

public enum WritingTool: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case pen, marker, strokeEraser, precisionEraser, inkSelection, text, image, shape, selection, read, pencil, laser
    public var id: String { rawValue }
    /// Tools of formats 1–7; format 8 adds `pencil` and `laser`.
    public static let format7Tools: [WritingTool] = [.pen, .marker, .strokeEraser, .precisionEraser, .inkSelection, .text, .image, .shape, .selection, .read]
    /// Stroke tools that write native PencilKit ink with colour/width.
    public var isInk: Bool { self == .pen || self == .pencil || self == .marker }
}

public enum ToolbarDock: String, Codable, CaseIterable, Hashable, Sendable { case top, bottom, left, right, floating }

public struct InkColor: Codable, Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ToolbarError.invalid
        }
    }
}

/// Highlighter tip (Build 45). Round writes PencilKit monoline ink at
/// highlighter opacity (round caps, constant width); chisel keeps PencilKit's
/// native marker ink. Stored optionally in format 8 (nil = round): older
/// format-8 builds ignore the unknown key.
public enum MarkerTip: String, Codable, CaseIterable, Hashable, Sendable { case round, chisel }

public struct InkPreset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var tool: WritingTool
    public var color: InkColor
    public var width: Double
    /// Marker favourites only (optional, format 8); nil keeps the current tip.
    public var markerTip: MarkerTip?
    public init(tool: WritingTool, color: InkColor, width: Double, markerTip: MarkerTip? = nil) {
        self.tool = tool; self.color = color; self.width = width; self.markerTip = markerTip
    }
}

public struct ToolbarPreferences: Codable, Equatable, Sendable {
    public static let currentFormat = 8
    /// Default order of formats 4–7 (before pencil and laser pointer).
    public static let format7Order: [WritingTool] = [.pen, .marker, .strokeEraser, .text, .selection, .shape, .image, .read, .precisionEraser, .inkSelection]
    public static let pencilWidths = 1.0...16.0
    public static let defaultPencilColor = InkColor(0.23, 0.23, 0.25)
    public static let defaultLaserColor = InkColor(1, 0.16, 0.2)
    public var formatVersion = Self.currentFormat
    public var dock: ToolbarDock = .top
    public var order: [WritingTool] = Self.addingFormat8Tools(to: Self.format7Order)
    public var penColor = InkColor(0, 0, 0)
    public var markerColor = InkColor(1, 1, 0)
    public var penWidth = 2.0
    public var markerWidth = 14.0
    public var eraserWidth = 16.0
    public var fingerDrawing = false
    public var autoPen: Bool?
    public var pencilPreview: Bool?
    public var paging: Bool?
    public var eraserPrecision: Bool?
    public var floatingAxis: ToolbarAxis?
    public var dockOnly: Bool?
    public var normalizePageWidths: Bool?
    public var shapeKind: ShapeKind?
    public var shapePattern: StrokePattern?
    public var shapeFilled: Bool?
    /// Fill of new shapes (optional, format 8; older builds ignore the keys):
    /// own colour (nil = stroke colour) and strength 0.1–1 (nil = 0.2).
    public var shapeFillColor: InkColor?
    public var shapeFillOpacity: Double?
    public var recognizeShapes: Bool?
    /// Highlighter: straighten a held line (optional, v7-compatible; nil = on).
    /// Separate from `recognizeShapes`, so turning it off for the highlighter
    /// no longer switches off pen/pencil shape recognition.
    public var markerHoldStraighten: Bool?
    public var ruler: Bool?
    /// Highlighter strokes snap to one horizontal/vertical segment (optional, v7-compatible).
    public var markerStraight: Bool?
    /// Highlighter tip (optional, format 8; nil = round).
    public var markerTip: MarkerTip?
    /// Scribbling over pen ink erases it (optional, v7-compatible; nil = on).
    public var scribbleErase: Bool?
    /// Paper/cover default for newly created notebooks (optional, v7-compatible;
    /// older builds ignore the unknown key).
    public var defaultAppearance: NotebookAppearance?
    /// Format 8: graphite pencil (PencilKit pencil ink) and its own Autostift.
    public var pencilColor: InkColor?
    public var pencilWidth: Double?
    public var autoPencil: Bool?
    /// Format 8: laser pointer look; display only, never notebook content.
    public var laserColor: InkColor?
    public var laserMode: LaserMode?
    public var laserFade: LaserFade?
    /// Normalized position of the floating palette's leading/top corner.
    public var floatingX = 0.0
    public var floatingY = 0.0
    public var presets: [InkPreset] = []
    public init() {}

    public var effectivePencilColor: InkColor { pencilColor ?? Self.defaultPencilColor }
    public var effectiveMarkerTip: MarkerTip { markerTip ?? .round }
    /// Colour handed to PencilKit for new highlighter strokes: the chosen
    /// colour at the tip's highlighter opacity (`MarkerInk`).
    public var markerStrokeColor: InkColor {
        var color = markerColor
        color.alpha *= MarkerInk.opacity(for: effectiveMarkerTip)
        return color
    }
    public var effectivePencilWidth: Double { pencilWidth ?? 3 }
    public var laserStyle: LaserPointerStyle {
        LaserPointerStyle(color: laserColor ?? Self.defaultLaserColor, mode: laserMode ?? .trail, fade: laserFade ?? .medium)
    }
    /// Format 7 → 8: the pencil follows the pen, the laser pointer the PDF read tool.
    public static func addingFormat8Tools(to order: [WritingTool]) -> [WritingTool] {
        var result = order.filter { $0 != .pencil && $0 != .laser }
        result.insert(.pencil, at: result.firstIndex(of: .pen).map { $0 + 1 } ?? 0)
        result.insert(.laser, at: result.firstIndex(of: .read).map { $0 + 1 } ?? result.endIndex)
        return result
    }
    /// Colour/width of an ink tool; shapes and other tools use the pen's.
    public func inkColor(for tool: WritingTool) -> InkColor {
        switch tool {
        case .marker: markerColor
        case .pencil: effectivePencilColor
        default: penColor
        }
    }
    public func inkWidth(for tool: WritingTool) -> Double {
        switch tool {
        case .marker: markerWidth
        case .pencil: effectivePencilWidth
        case .precisionEraser: eraserWidth
        default: penWidth
        }
    }
    /// Picking a colour turns that tool's Autostift off.
    public mutating func setInkColor(_ color: InkColor, for tool: WritingTool) {
        switch tool {
        case .marker: markerColor = color
        case .pencil: pencilColor = color; autoPencil = false
        default:
            // The pencil keeps what it showed while it followed the pen.
            if autoPencil == nil { autoPencil = autoPen }
            penColor = color; autoPen = false
        }
    }
    public mutating func setInkWidth(_ width: Double, for tool: WritingTool) {
        switch tool {
        case .marker: markerWidth = width
        case .pencil: pencilWidth = width
        case .precisionEraser: eraserWidth = width
        default: penWidth = width
        }
    }
    /// Autostift (black/white by the paper below) for pen/shapes and the pencil.
    /// The pencil follows the pen's Autostift unless it was set apart
    /// (`autoPencil` non-nil: own toggle or an explicitly picked pencil colour).
    public func automaticInk(for tool: WritingTool) -> Bool {
        switch tool {
        case .pen, .shape: autoPen ?? false
        case .pencil: autoPencil ?? autoPen ?? false
        default: false
        }
    }
    /// Toggling the pen's Autostift links the pencil to it again; toggling the
    /// pencil's own keeps it separate only while it differs from the pen.
    public mutating func setAutomaticInk(_ on: Bool, for tool: WritingTool) {
        switch tool {
        case .pen, .shape: autoPen = on; autoPencil = nil
        case .pencil: autoPencil = on == (autoPen ?? false) ? nil : on
        default: break
        }
    }
    public static func widthRange(for tool: WritingTool) -> ClosedRange<Double>? {
        switch tool {
        case .pen: 1...12
        case .pencil: pencilWidths
        case .marker: 4...40
        default: nil
        }
    }

    /// Keep legacy serialized tool IDs/order while exposing exactly one lasso.
    public var mainTools: [WritingTool] {
        order.filter { $0 != .precisionEraser && $0 != .inkSelection }.map { $0 == .selection ? .inkSelection : $0 }
    }
    /// Shown on the toolbar's second level next to the utilities (Build 45:
    /// laser pointer and „PDF lesen“). Derived, not stored: the saved order
    /// (format 8) stays unchanged and older builds read it as before.
    public static let secondLevelTools: Set<WritingTool> = [.read, .laser]
    /// Tools on the toolbar's first level, in the saved order.
    public var primaryTools: [WritingTool] { mainTools.filter { !Self.secondLevelTools.contains($0) } }
    /// Tools on the second level, in the saved order.
    public var secondaryTools: [WritingTool] { mainTools.filter { Self.secondLevelTools.contains($0) } }
    /// Reorders a subset of `mainTools` (one toolbar level) in place: `visible`
    /// is the new order of exactly those tools; all other slots stay untouched.
    public mutating func reorderTools(_ visible: [WritingTool]) {
        let members = Set(visible)
        func shown(_ stored: WritingTool) -> WritingTool? {
            stored == .precisionEraser || stored == .inkSelection ? nil : stored == .selection ? .inkSelection : stored
        }
        let slots = order.indices.filter { shown(order[$0]).map(members.contains) ?? false }
        guard slots.count == visible.count, members.count == visible.count else { return }
        for (slot, item) in zip(slots, visible) { order[slot] = item == .inkSelection ? .selection : item }
    }

    public var effectiveDock: ToolbarDock { dockOnly != false && dock == .floating ? .top : dock }
    public func dropDestination(near target: ToolbarDock?) -> ToolbarDock {
        target ?? (dockOnly == false ? .floating : effectiveDock)
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormat else { throw ToolbarError.unsupported(formatVersion) }
        guard order.count == WritingTool.allCases.count, Set(order) == Set(WritingTool.allCases),
              penWidth.isFinite, (1...12).contains(penWidth), markerWidth.isFinite, (4...40).contains(markerWidth),
              eraserWidth.isFinite, (4...60).contains(eraserWidth),
              pencilWidth.map({ $0.isFinite && Self.pencilWidths.contains($0) }) ?? true,
              shapeFillOpacity.map({ $0.isFinite && ShapeFill.opacityRange.contains($0) }) ?? true,
              [floatingX, floatingY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              presets.count <= 12, Set(presets.map(\.id)).count == presets.count else { throw ToolbarError.invalid }
        try penColor.validate(); try markerColor.validate(); try pencilColor?.validate(); try laserColor?.validate(); try shapeFillColor?.validate()
        do { try defaultAppearance?.validate() } catch { throw ToolbarError.invalid }
        for preset in presets {
            guard preset.tool.isInk, let range = Self.widthRange(for: preset.tool), preset.width.isFinite,
                  range.contains(preset.width), preset.markerTip == nil || preset.tool == .marker else { throw ToolbarError.invalid }
            try preset.color.validate()
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).formatVersion
        guard (1...Self.currentFormat).contains(version) else { throw ToolbarError.unsupported(version) }
        var value = try JSONDecoder().decode(Self.self, from: data)
        if version < 8, value.order.contains(.pencil) || value.order.contains(.laser) || value.presets.contains(where: { $0.tool == .pencil })
            || value.pencilColor != nil || value.pencilWidth != nil || value.autoPencil != nil
            || value.laserColor != nil || value.laserMode != nil || value.laserFade != nil
            || value.markerTip != nil || value.presets.contains(where: { $0.markerTip != nil }) { throw ToolbarError.invalid }
        if version < 5, value.floatingAxis != nil { throw ToolbarError.invalid }
        if version < 6, value.dockOnly != nil { throw ToolbarError.invalid }
        if version < 7, value.normalizePageWidths != nil { throw ToolbarError.invalid }
        if version < 4, value.dock == .bottom || value.autoPen != nil || value.pencilPreview != nil || value.paging != nil || value.eraserPrecision != nil {
            throw ToolbarError.invalid
        }
        if version == 1 {
            let legacyTools = WritingTool.format7Tools.filter { ![.image, .shape, .selection].contains($0) }
            guard value.order.count == legacyTools.count, Set(value.order) == Set(legacyTools) else { throw ToolbarError.invalid }
            value.order.insert(.image, at: value.order.firstIndex(of: .read) ?? value.order.endIndex)
            value.formatVersion = 2
        }
        if value.formatVersion == 2 {
            let oldTools = WritingTool.format7Tools.filter { ![.shape, .selection].contains($0) }
            guard value.order.count == oldTools.count, Set(value.order) == Set(oldTools) else { throw ToolbarError.invalid }
            let offset = value.order.firstIndex(of: .read) ?? value.order.endIndex
            value.order.insert(contentsOf: [.shape, .selection], at: offset)
            value.formatVersion = 3
        }
        if value.formatVersion == 3 {
            if value.order == WritingTool.format7Tools { value.order = Self.format7Order }
            value.formatVersion = 4
        }
        if value.formatVersion == 4 { value.formatVersion = 5 }
        if value.formatVersion == 5 { value.formatVersion = 6 }
        if value.formatVersion == 6 { value.formatVersion = 7 }
        if value.formatVersion == 7 {
            guard value.order.count == WritingTool.format7Tools.count, Set(value.order) == Set(WritingTool.format7Tools) else { throw ToolbarError.invalid }
            value.order = Self.addingFormat8Tools(to: value.order)
            value.formatVersion = 8
        }
        try value.validate(); return value
    }
}

public enum ToolbarError: Error, LocalizedError {
    case invalid, unsupported(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Werkzeugeinstellungen sind nicht lesbar. Vorhandene Dateien bleiben erhalten."
        case .unsupported(let version): "Werkzeugformat \(version) benötigt eine neuere noty-Version."
        }
    }
}

public actor ToolbarPreferenceStore {
    private let root: URL
    private var loaded = false
    private var lastGood: Data?
    private var latestRevision = 0
    private var recovered = false
    public init(root: URL) { self.root = root }

    public func load() throws -> (ToolbarPreferences, Bool) {
        let value = try Self.read(root: root)
        loaded = true
        lastGood = value.2
        recovered = value.1
        return (value.0, value.1)
    }

    static func read(root: URL) throws -> (ToolbarPreferences, Bool, Data?) {
        let fm = FileManager.default
        var exists = false
        for name in ["toolbar.json", "toolbar-previous.json"] {
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            exists = true
            do {
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw ToolbarError.invalid }
                let data = try BackupArchive.readBounded(url, limit: 64_000)
                return (try ToolbarPreferences.decode(data), name != "toolbar.json", data)
            } catch ToolbarError.unsupported(let version) { throw ToolbarError.unsupported(version) }
            catch { continue }
        }
        guard !exists else { throw ToolbarError.invalid }
        return (ToolbarPreferences(), false, nil)
    }

    public func save(_ preferences: ToolbarPreferences, revision: Int) throws {
        guard revision >= latestRevision else { return }
        if !loaded { _ = try load() }
        try preferences.validate()
        let data = try JSONEncoder().encode(preferences)
        guard data.count <= 64_000 else { throw ToolbarError.invalid }
        if recovered || lastGood.flatMap({ try? ToolbarPreferences.decode($0) }) != preferences {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let lastGood {
                try Self.preserveOlderFormat(lastGood, root: root)
                try lastGood.write(to: root.appendingPathComponent("toolbar-previous.json"), options: .atomic)
            }
            try data.write(to: root.appendingPathComponent("toolbar.json"), options: .atomic)
            lastGood = data
            recovered = false
        }
        latestRevision = revision
    }

    /// Exact confirmed bytes of an older format stay once as
    /// `toolbar-format<N>.json` before the first commit in the current format;
    /// if that copy fails, nothing is committed.
    static func preserveOlderFormat(_ data: Data, root: URL) throws {
        struct Header: Decodable { var formatVersion: Int }
        guard let version = try? JSONDecoder().decode(Header.self, from: data).formatVersion,
              version < ToolbarPreferences.currentFormat else { return }
        let url = root.appendingPathComponent("toolbar-format\(version).json")
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue { return }
        try data.write(to: url, options: .atomic)
    }
}
