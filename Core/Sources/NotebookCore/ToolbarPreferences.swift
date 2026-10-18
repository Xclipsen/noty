import Foundation

public enum WritingTool: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case pen, marker, strokeEraser, precisionEraser, inkSelection, text, image, shape, selection, read
    public var id: String { rawValue }
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

public struct InkPreset: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var tool: WritingTool
    public var color: InkColor
    public var width: Double
    public init(tool: WritingTool, color: InkColor, width: Double) { self.tool = tool; self.color = color; self.width = width }
}

public struct ToolbarPreferences: Codable, Equatable, Sendable {
    public var formatVersion = 7
    public var dock: ToolbarDock = .top
    public var order: [WritingTool] = [.pen, .marker, .strokeEraser, .text, .selection, .shape, .image, .read, .precisionEraser, .inkSelection]
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
    public var recognizeShapes: Bool?
    public var ruler: Bool?
    /// Normalized position of the floating palette's leading/top corner.
    public var floatingX = 0.0
    public var floatingY = 0.0
    public var presets: [InkPreset] = []
    public init() {}

    public var effectiveDock: ToolbarDock { dockOnly != false && dock == .floating ? .top : dock }
    public func dropDestination(near target: ToolbarDock?) -> ToolbarDock {
        target ?? (dockOnly == false ? .floating : effectiveDock)
    }

    public func validate() throws {
        guard formatVersion == 7 else { throw ToolbarError.unsupported(formatVersion) }
        guard order.count == WritingTool.allCases.count, Set(order) == Set(WritingTool.allCases),
              penWidth.isFinite, (1...12).contains(penWidth), markerWidth.isFinite, (4...40).contains(markerWidth),
              eraserWidth.isFinite, (4...60).contains(eraserWidth),
              [floatingX, floatingY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              presets.count <= 12, Set(presets.map(\.id)).count == presets.count else { throw ToolbarError.invalid }
        try penColor.validate(); try markerColor.validate()
        for preset in presets {
            guard preset.tool == .pen || preset.tool == .marker, preset.width.isFinite,
                  (preset.tool == .pen ? 1...12 : 4...40).contains(preset.width) else { throw ToolbarError.invalid }
            try preset.color.validate()
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).formatVersion
        guard (1...7).contains(version) else { throw ToolbarError.unsupported(version) }
        var value = try JSONDecoder().decode(Self.self, from: data)
        if version < 5, value.floatingAxis != nil { throw ToolbarError.invalid }
        if version < 6, value.dockOnly != nil { throw ToolbarError.invalid }
        if version < 7, value.normalizePageWidths != nil { throw ToolbarError.invalid }
        if version < 4, value.dock == .bottom || value.autoPen != nil || value.pencilPreview != nil || value.paging != nil || value.eraserPrecision != nil {
            throw ToolbarError.invalid
        }
        if version == 1 {
            let legacyTools = WritingTool.allCases.filter { ![.image, .shape, .selection].contains($0) }
            guard value.order.count == legacyTools.count, Set(value.order) == Set(legacyTools) else { throw ToolbarError.invalid }
            value.order.insert(.image, at: value.order.firstIndex(of: .read) ?? value.order.endIndex)
            value.formatVersion = 2
        }
        if value.formatVersion == 2 {
            let oldTools = WritingTool.allCases.filter { ![.shape, .selection].contains($0) }
            guard value.order.count == oldTools.count, Set(value.order) == Set(oldTools) else { throw ToolbarError.invalid }
            let offset = value.order.firstIndex(of: .read) ?? value.order.endIndex
            value.order.insert(contentsOf: [.shape, .selection], at: offset)
            value.formatVersion = 3
        }
        if value.formatVersion == 3 {
            if value.order == WritingTool.allCases { value.order = ToolbarPreferences().order }
            value.formatVersion = 4
        }
        if value.formatVersion == 4 { value.formatVersion = 5 }
        if value.formatVersion == 5 { value.formatVersion = 6 }
        if value.formatVersion == 6 { value.formatVersion = 7 }
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
            if let lastGood { try lastGood.write(to: root.appendingPathComponent("toolbar-previous.json"), options: .atomic) }
            try data.write(to: root.appendingPathComponent("toolbar.json"), options: .atomic)
            lastGood = data
            recovered = false
        }
        latestRevision = revision
    }
}
