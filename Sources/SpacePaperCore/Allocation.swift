import Foundation

public struct WallpaperAsset: Codable, Equatable {
    public let id: String
    public let path: String
    public let name: String

    public init(id: String, path: String, name: String) {
        self.id = id; self.path = path; self.name = name
    }
}

public struct AllocationPlan: Equatable {
    public let assignments: [String: String]
    public let unassigned: [String]
    public var isComplete: Bool { unassigned.isEmpty }
}

public enum Allocator {
    /// Reserve images for ALL attached desktop Spaces, including the hidden ones.
    /// Detached display records do not consume capacity. No reuse on exhaustion.
    public static func plan(slots: [String], previous: [String: String],
                            observed: [String: String], assets: [String]) -> AllocationPlan {
        let slots = Array(Set(slots)).sorted()
        let assetIDs = Array(Set(assets)).sorted()
        let valid = Set(assetIDs)
        var result: [String: String] = [:]
        var used = Set<String>()

        // Preserve an already-correct visible desktop before hidden/offline reservations.
        let prioritized = slots.filter { previous[$0] != nil && observed[$0] == previous[$0] }
        let rest = slots.filter { !prioritized.contains($0) }
        for slot in prioritized + rest {
            if let id = previous[slot], valid.contains(id), used.insert(id).inserted {
                result[slot] = id
            }
        }
        // Preserve a currently visible wallpaper when it does not steal a reservation.
        for slot in slots where result[slot] == nil {
            if let id = observed[slot], valid.contains(id), used.insert(id).inserted {
                result[slot] = id
            }
        }
        var available = assetIDs.filter { !used.contains($0) }.makeIterator()
        var missing: [String] = []
        for slot in slots where result[slot] == nil {
            if let id = available.next() { result[slot] = id }
            else { missing.append(slot) }
        }
        return AllocationPlan(assignments: result, unassigned: missing)
    }
}

public struct DesktopSpace: Equatable {
    public let id: UInt64
    public let uuid: String
    public let type: Int
    public var isDesktop: Bool { type == 0 }
}

public struct DisplaySpaces: Equatable {
    public let displayID: String
    public let spaces: [DesktopSpace]
    public let currentID: UInt64
    public var current: DesktopSpace? { spaces.first { $0.id == currentID } }
}

public enum SnapshotError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "Space情報を取得できません: \(reason)" }
    }
}

public enum SpaceParser {
    /// Validate private API data strictly. A failed/partial read must never cause writes.
    public static func parse(_ raw: [[String: Any]]) throws -> [DisplaySpaces] {
        guard !raw.isEmpty else { throw SnapshotError.invalid("画面一覧が空です") }
        var displays: [DisplaySpaces] = []
        var seenDisplays = Set<String>()
        for group in raw {
            guard let display = group["Display Identifier"] as? String,
                  !display.isEmpty, seenDisplays.insert(display).inserted,
                  let list = group["Spaces"] as? [[String: Any]], !list.isEmpty,
                  let current = group["Current Space"] as? [String: Any],
                  let currentID = number(current) else {
                throw SnapshotError.invalid("画面または現在のSpaceの形式が不明です")
            }
            var spaces: [DesktopSpace] = []
            var seen = Set<String>()
            for entry in list {
                guard let id = number(entry), let type = entry["type"] as? NSNumber,
                      let uuid = entry["uuid"] as? String, !uuid.isEmpty,
                      seen.insert(uuid).inserted else {
                    throw SnapshotError.invalid("Spaceの識別子が不明です")
                }
                spaces.append(DesktopSpace(id: id, uuid: uuid, type: type.intValue))
            }
            guard spaces.contains(where: { $0.id == currentID }) else {
                throw SnapshotError.invalid("現在のSpaceが一覧と一致しません")
            }
            displays.append(DisplaySpaces(displayID: display, spaces: spaces, currentID: currentID))
        }
        return displays
    }

    private static func number(_ entry: [String: Any]) -> UInt64? {
        (entry["ManagedSpaceID"] as? NSNumber ?? entry["id64"] as? NSNumber)?.uint64Value
    }

    public static func slot(display: String, space: DesktopSpace) -> String {
        "\(display.uppercased())/\(space.uuid.uppercased())"
    }
}
