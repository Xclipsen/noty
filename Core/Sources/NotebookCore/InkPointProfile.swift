import Foundation

/// How PencilKit draws a stroke of one ink type, learned from the user's own
/// strokes: point size per tool width, opacity, force and tilt of a typical
/// (median) point. Held shapes and ruler strokes are drawn with it. One shared
/// profile per ink type for every page and view, kept across launches
/// (`UserDefaults`, never in a notebook); before, each page view learned it
/// anew from the last stroke, so a fresh page drew too thin and the width
/// jumped with every stroke.
public struct InkPointProfile: Codable, Equatable, Sendable {
    public var widthRatio: Double
    public var opacity: Double
    public var force: Double
    public var altitude: Double
    public var azimuth: Double
    /// Strokes learned so far (capped): the first ones count fully, later
    /// ones only move the profile a little.
    public var strokes: Int
}

public struct InkPointProfiles: Codable, Equatable, Sendable {
    public private(set) var inks: [String: InkPointProfile] = [:]
    /// A new stroke moves the profile by at least this share of the difference.
    public static let minimumWeight = 0.15
    public init() {}
    /// Tolerant: unreadable stored data is an empty profile, never an error.
    public init(data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { self.init(); return }
        self = decoded
    }
    public subscript(ink: String) -> InkPointProfile? { inks[ink] }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public mutating func learn(_ ink: String, widthRatio: Double, opacity: Double, force: Double, altitude: Double, azimuth: Double) {
        guard widthRatio.isFinite, widthRatio > 0.05, widthRatio < 20, opacity.isFinite, force.isFinite,
              altitude.isFinite, azimuth.isFinite else { return }
        let opacity = min(1, max(0, opacity)), force = max(0, force)
        guard var profile = inks[ink] else {
            inks[ink] = InkPointProfile(widthRatio: widthRatio, opacity: opacity, force: force, altitude: altitude, azimuth: azimuth, strokes: 1)
            return
        }
        let weight = max(Self.minimumWeight, 1 / Double(profile.strokes + 1))
        func blend(_ old: Double, _ new: Double) -> Double { old + (new - old) * weight }
        profile.widthRatio = blend(profile.widthRatio, widthRatio)
        profile.opacity = blend(profile.opacity, opacity)
        profile.force = blend(profile.force, force)
        profile.altitude = blend(profile.altitude, altitude)
        profile.azimuth = azimuth
        profile.strokes = min(profile.strokes + 1, 100)
        inks[ink] = profile
    }
}
