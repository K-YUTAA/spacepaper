import Foundation

public struct ReservationHistory: Equatable {
    public let assignments: [String: String]
    public let lastSeen: [String: Date]

    public static func prune(assignments: [String: String], lastSeen: [String: Date],
                             displays: Set<String>, slots: Set<String>, now: Date) -> ReservationHistory {
        var dates = lastSeen
        var kept: [String: String] = [:]
        for (slot, image) in assignments {
            let display = String(slot.split(separator: "/", maxSplits: 1).first ?? "")
            if displays.contains(display) {
                if slots.contains(slot) { kept[slot] = image }
            } else {
                let seen = dates[display] ?? now
                dates[display] = seen
                if now.timeIntervalSince(seen) < 30 * 86400 { kept[slot] = image }
            }
        }
        for display in displays where dates[display] == nil || now.timeIntervalSince(dates[display]!) >= 3600 {
            dates[display] = now
        }
        let retained = Set(kept.keys.map { String($0.split(separator: "/", maxSplits: 1).first ?? "") }).union(displays)
        dates = dates.filter { retained.contains($0.key) }
        return ReservationHistory(assignments: kept, lastSeen: dates)
    }
}

/// Do not mistake delayed read-back from macOS for a failed write.
public struct ApplyTracker {
    private struct Attempt { let image: String; let time: Date; let count: Int }
    private var attempts: [String: Attempt] = [:]
    public init() {}
    public mutating func shouldApply(slot: String, expected: String, actual: String?, now: Date) -> Bool {
        if actual == expected { attempts.removeValue(forKey: slot); return false }
        guard let attempt = attempts[slot], attempt.image == expected else { return true }
        let delay = min(60.0, 5.0 * pow(2.0, Double(min(4, attempt.count - 1))))
        return now.timeIntervalSince(attempt.time) >= delay
    }
    public mutating func didApply(slot: String, image: String, now: Date) {
        let count = attempts[slot]?.image == image ? attempts[slot]!.count + 1 : 1
        attempts[slot] = Attempt(image: image, time: now, count: count)
    }
    public mutating func keepOnly(_ slots: Set<String>) { attempts = attempts.filter { slots.contains($0.key) } }
}

public enum BackupFile {
    public static func ensure(source: URL, target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: target), format: nil)
            return
        }
        let data = try Data(contentsOf: source)
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}
