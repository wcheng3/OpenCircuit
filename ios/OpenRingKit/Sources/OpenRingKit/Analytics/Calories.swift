import Foundation

public struct HRSample: Equatable, Codable, Sendable {
    public let bpm: Int
    public let start: Date
    public let end: Date

    public init(bpm: Int, start: Date, end: Date? = nil) {
        self.bpm = bpm
        self.start = start
        self.end = end ?? start
    }
}

public enum Calories {
    public static let trimpKcalFactor = 5.0
    public static let defaultRestingHR = 60

    public static func bmrKcalPerDay(profile: UserProfile) -> Double {
        let base = (10.0 * profile.weightKg)
            + (6.25 * profile.heightCm)
            - (5.0 * Double(profile.age))
        switch profile.sex {
        case .male: return base + 5.0
        case .female: return base - 161.0
        }
    }

    public static func bmrKcalPerHour(profile: UserProfile) -> Double {
        bmrKcalPerDay(profile: profile) / 24.0
    }

    public static func activeKcal(hrSamples: [HRSample], maxHR: Int) -> Double {
        guard let trimp = Strain.edwardsTRIMP(
            hrSamples: hrSamples,
            maxHR: maxHR,
            restingHR: defaultRestingHR
        ) else {
            return 0.0
        }
        return trimp * trimpKcalFactor
    }
}
