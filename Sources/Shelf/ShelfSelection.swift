import Foundation

/// Which files are selected on the shelf or in the basket, with the usual Mac rules:
/// click selects one, Command-click adds or removes one, Shift-click selects everything between.
struct ShelfSelection: Equatable {
    var ids: Set<UUID> = []
    var anchor: UUID?

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// `order` is the files as they appear, left to right, top to bottom.
    mutating func click(_ id: UUID, order: [UUID], command: Bool, shift: Bool) {
        if shift, let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            let range = order[min(i, j)...max(i, j)]
            ids = command ? ids.union(range) : Set(range)          // the anchor stays, so the range can be changed
            return
        }
        if command {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            return
        }
        if ids == [id] { return }
        ids = [id]
        anchor = id
    }

    mutating func selectAll(_ order: [UUID]) {
        ids = Set(order)
        anchor = order.first
    }

    mutating func select(_ newIDs: Set<UUID>, anchor a: UUID? = nil) {
        ids = newIDs
        anchor = a ?? newIDs.first
    }

    mutating func clear() { ids = []; anchor = nil }

    /// Forgets files that are no longer there.
    mutating func prune(keeping order: [UUID]) {
        let alive = Set(order)
        let kept = ids.intersection(alive)
        if kept != ids { ids = kept }
        if let a = anchor, !alive.contains(a) { anchor = kept.first }
    }

    /// The selected files in display order.
    func ordered(_ order: [UUID]) -> [UUID] { order.filter { ids.contains($0) } }
}
