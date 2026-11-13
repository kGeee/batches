import CoreGraphics
import Foundation

/// How someone arranges their own desk. It's theirs alone: friends see your batches in a plain
/// grid on your profile. Everything here is by id, so a batch deleted elsewhere just drops out.
struct DeskLayout: Hashable, Codable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case grid, sideways, freehand
        var id: String { rawValue }

        var title: String {
            switch self {
            case .grid: "Grid"
            case .sideways: "Sideways"
            case .freehand: "Freehand"
            }
        }

        var symbol: String {
            switch self {
            case .grid: "square.grid.2x2"
            case .sideways: "rectangle.split.3x1"
            case .freehand: "hand.draw"
            }
        }
    }

    var mode: Mode = .grid
    /// Tile ids in grid and sideways order. New batches aren't in it yet and come first.
    var order: [String] = []
    var groups: [DeskGroup] = []
    /// Tile centers on the freehand desk, in points.
    var positions: [String: CGPoint] = [:]
    /// Piles lie at loose angles instead of squared up. Off unless you turn it on.
    var tiltedPiles = false

    init() {}

    // A layout written by a newer build still opens: anything unknown falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .grid
        order = (try? c.decode([String].self, forKey: .order)) ?? []
        groups = (try? c.decode([DeskGroup].self, forKey: .groups)) ?? []
        positions = (try? c.decode([String: CGPoint].self, forKey: .positions)) ?? [:]
        tiltedPiles = (try? c.decode(Bool.self, forKey: .tiltedPiles)) ?? false
    }

    /// What sits on the desk, in order: batches on their own, and groups of them.
    func tiles(for piles: [PhotoCollection]) -> [DeskTile] {
        let grouped = Set(groups.flatMap(\.pileIDs))
        var byID: [String: DeskTile] = [:]
        for pile in piles where !grouped.contains(pile.id) { byID[Self.key(pile.id)] = .pile(pile) }
        for group in groups {
            let members = group.pileIDs.compactMap { id in piles.first { $0.id == id } }
            if !members.isEmpty { byID[Self.key(group.id)] = .group(group, members) }
        }
        let ordered = order.filter { byID[$0] != nil }
        let known = Set(ordered)
        // Anything not arranged yet, in the order it came (newest batches first).
        var fresh: [String] = piles.map { Self.key($0.id) }.filter { byID[$0] != nil && !known.contains($0) }
        fresh += groups.map { Self.key($0.id) }.filter { byID[$0] != nil && !known.contains($0) }
        return (fresh + ordered).compactMap { byID[$0] }
    }

    /// Drops batches that no longer exist, and groups with fewer than two left in them.
    func normalized(keeping piles: [PhotoCollection]) -> DeskLayout {
        let alive = Set(piles.map(\.id))
        var next = self
        next.groups = groups.compactMap { group in
            var group = group
            group.pileIDs.removeAll { !alive.contains($0) }
            return group.pileIDs.count >= 2 ? group : nil
        }
        let aliveKeys = Set(alive.map(Self.key)).union(next.groups.map { Self.key($0.id) })
        next.order = order.filter(aliveKeys.contains)
        next.positions = positions.filter { aliveKeys.contains($0.key) }
        return next
    }

    /// Puts the tile `moved` together with `target`. A group keeps its name; two loose batches
    /// start a new group where the target was. Returns the id of the group they end up in.
    @discardableResult
    mutating func group(_ moved: DeskTile, onto target: DeskTile) -> UUID? {
        guard moved.id != target.id else { return nil }
        let incoming = moved.pileIDs
        let result: UUID
        if case .group(let existing, _) = target, let i = groups.firstIndex(where: { $0.id == existing.id }) {
            groups[i].pileIDs += incoming.filter { !groups[i].pileIDs.contains($0) }
            result = existing.id
        } else {
            let new = DeskGroup(id: UUID(), title: "New group", pileIDs: target.pileIDs + incoming)
            groups.append(new)
            result = new.id
            // The new group takes the target's place on the desk.
            let newKey = Self.key(new.id)
            if let i = order.firstIndex(of: target.id) { order[i] = newKey } else { order.insert(newKey, at: 0) }
            if let spot = positions[target.id] { positions[newKey] = spot }
        }
        if case .group(let gone, _) = moved { groups.removeAll { $0.id == gone.id } }
        order.removeAll { $0 == moved.id }
        positions[moved.id] = nil
        return result
    }

    /// Takes a batch out of its group. It lands next to where the group was.
    mutating func takeOut(_ pileID: UUID, from groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].pileIDs.removeAll { $0 == pileID }
        let groupKey = Self.key(groupID)
        let pileKey = Self.key(pileID)
        if let at = order.firstIndex(of: groupKey) { order.insert(pileKey, at: at + 1) }
        if let spot = positions[groupKey] { positions[pileKey] = CGPoint(x: spot.x + 40, y: spot.y + 40) }
    }

    /// Breaks a group up. Its batches go back on the desk where it was.
    mutating func ungroup(_ groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups.remove(at: i)
        let groupKey = Self.key(groupID)
        let keys = group.pileIDs.map(Self.key)
        if let at = order.firstIndex(of: groupKey) {
            order.replaceSubrange(at...at, with: keys)
        }
        if let spot = positions.removeValue(forKey: groupKey) {
            for (n, key) in keys.enumerated() {
                positions[key] = CGPoint(x: spot.x + CGFloat(n % 2) * 170, y: spot.y + CGFloat(n / 2) * 220)
            }
        }
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    // MARK: Freehand

    static let tileWidth: CGFloat = 168
    /// The tile's pile plus the longest caption it shows.
    static let tileHeight: CGFloat = 244

    /// Where each tile sits on the freehand desk: its saved spot, or the next free one.
    func freehandPositions(for tiles: [DeskTile]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        for tile in tiles { if let spot = positions[tile.id] { result[tile.id] = spot } }
        var slot = 0
        for tile in tiles where result[tile.id] == nil {
            var candidate: CGPoint
            repeat {
                candidate = CGPoint(x: Self.tileWidth / 2 + 14 + CGFloat(slot % 2) * (Self.tileWidth + 18),
                                    y: Self.tileHeight / 2 + 8 + CGFloat(slot / 2) * (Self.tileHeight + 14))
                slot += 1
            } while result.values.contains { abs($0.x - candidate.x) < Self.tileWidth * 0.8 && abs($0.y - candidate.y) < Self.tileHeight * 0.8 }
            result[tile.id] = candidate
        }
        return result
    }
}

/// Batches kept together on the desk, in any layout.
struct DeskGroup: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var pileIDs: [UUID]
}

enum DeskTile: Identifiable, Hashable {
    case pile(PhotoCollection)
    case group(DeskGroup, [PhotoCollection])

    var id: String {
        switch self {
        case .pile(let pile): DeskLayout.key(pile.id)
        case .group(let group, _): DeskLayout.key(group.id)
        }
    }

    var pileIDs: [UUID] {
        switch self {
        case .pile(let pile): [pile.id]
        case .group(_, let piles): piles.map(\.id)
        }
    }

    var title: String {
        switch self {
        case .pile(let pile): pile.title
        case .group(let group, _): group.title
        }
    }
}
