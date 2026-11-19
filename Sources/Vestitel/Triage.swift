import Foundation

/// Keyboard triage of the Inbox: a cursor over what the list shows (group
/// headers and article rows, in order), moved and acted on from the keys.
/// The pointer path (hover-revealed ×, swipe) is one decision per second
/// at best; a backlog wants one per keystroke.
enum TriageItem: Equatable {
    case header(groupID: String, firstArticle: String)
    case article(id: String, groupID: String?)

    /// What `AppStore.inboxCursor` holds for this item.
    var cursor: String {
        switch self {
        case .header(let groupID, _): return TriageItem.headerCursor(groupID)
        case .article(let id, _): return id
        }
    }

    static func headerCursor(_ groupID: String) -> String { "group:" + groupID }

    /// The list as drawn: a block has a header and, unless collapsed, its
    /// rows; a lone article is a row of its own.
    static func items(groups: [TopicGroup], collapsed: Set<String>) -> [TriageItem] {
        var items: [TriageItem] = []
        for group in groups {
            guard group.hasHeader, let first = group.articles.first else {
                if let only = group.articles.first { items.append(.article(id: only.id, groupID: nil)) }
                continue
            }
            items.append(.header(groupID: group.id, firstArticle: first.id))
            if !collapsed.contains(group.id) {
                for article in group.articles { items.append(.article(id: article.id, groupID: group.id)) }
            }
        }
        return items
    }

    /// Where the cursor lands after the item at `index` was cleared: the
    /// nearest item after it that is still there, else the nearest before.
    /// A topic group's id is its member ids, so a header whose group lost a
    /// member is found again through its first article.
    static func successor(of index: Int, in old: [TriageItem], now new: [TriageItem]) -> String? {
        let present = Set(new.map(\.cursor))
        func resolve(_ item: TriageItem) -> String? {
            if present.contains(item.cursor) { return item.cursor }
            guard case .header(_, let first) = item else { return nil }
            for candidate in new {
                if case .header(_, let f) = candidate, f == first { return candidate.cursor }
            }
            return present.contains(first) ? first : nil
        }
        for item in old.dropFirst(index + 1) { if let found = resolve(item) { return found } }
        for item in old.prefix(index).reversed() { if let found = resolve(item) { return found } }
        return nil
    }
}

enum TriageKey {
    case down, up, clear, open, bookmark, expand, collapse, expandAll, collapseAll, undo, escape
}

extension TopicGroup {
    /// Drawn as a block with a header (a story of several articles, or a
    /// source/section bucket) rather than as a bare row.
    var hasHeader: Bool { articles.count > 1 || sourceFeedID != nil }
}

extension AppStore {
    /// Applies a triage key to the Inbox. False when the key did nothing
    /// (it then goes on to whoever else wants it: Esc closes the popover).
    @discardableResult
    func triage(_ key: TriageKey) -> Bool {
        let groups = visibleGroupedInbox
        let items = TriageItem.items(groups: groups, collapsed: collapsedGroupIDs)
        let index = inboxCursor.flatMap { cursor in items.firstIndex { $0.cursor == cursor } }

        switch key {
        case .escape:
            guard inboxCursor != nil else { return false }
            inboxCursor = nil
            return true
        case .undo:
            return undoTriageClear()
        case .collapseAll:
            collapsedGroupIDs.formUnion(groups.filter(\.hasHeader).map(\.id))
            // a row that just folded away hands the cursor to its header
            if let index, case .article(_, let groupID?) = items[index] { inboxCursor = TriageItem.headerCursor(groupID) }
            return true
        case .expandAll:
            collapsedGroupIDs.removeAll()
            return true
        case .down, .up:
            guard !items.isEmpty else { return false }
            guard let index else { inboxCursor = items[0].cursor; return true }
            let next = key == .down ? min(index + 1, items.count - 1) : max(index - 1, 0)
            inboxCursor = items[next].cursor
            return true
        default:
            break
        }

        // the rest act on the item under the cursor
        guard let index else { return false }
        switch (key, items[index]) {
        case (.clear, .article(let id, _)):
            guard let article = articles.first(where: { $0.id == id }) else { return false }
            clear(article)
            triageUndo.append([id])
        case (.clear, .header(let groupID, _)):
            guard let group = groups.first(where: { $0.id == groupID }) else { return false }
            clearGroup(group)
            triageUndo.append(group.articles.map(\.id))
        case (.open, .article(let id, _)):
            guard let article = articles.first(where: { $0.id == id }) else { return false }
            open(article)
            return true
        case (.bookmark, .article(let id, _)):
            guard let article = articles.first(where: { $0.id == id }) else { return false }
            toggleBookmark(article)
            return true
        case (.open, .header(let groupID, _)):
            collapsedGroupIDs.formSymmetricDifference([groupID])
            return true
        case (.expand, .header(let groupID, _)):
            collapsedGroupIDs.remove(groupID)
            return true
        case (.collapse, .header(let groupID, _)):
            collapsedGroupIDs.insert(groupID)
            return true
        case (.collapse, .article(_, let groupID?)):
            inboxCursor = TriageItem.headerCursor(groupID)
            return true
        default:
            return false
        }

        // cleared: the cursor moves on to what took the item's place
        if triageUndo.count > 50 { triageUndo.removeFirst(triageUndo.count - 50) }
        let after = TriageItem.items(groups: visibleGroupedInbox, collapsed: collapsedGroupIDs)
        inboxCursor = TriageItem.successor(of: index, in: items, now: after)
        return true
    }

    /// Returns the last keyboard clear (a row or a whole block) to the
    /// inbox, one save for the lot, and puts the cursor back on it.
    private func undoTriageClear() -> Bool {
        guard let batch = triageUndo.popLast() else { return false }
        let ids = Set(batch)
        let now = Date()
        var restored = false
        for i in articles.indices where ids.contains(articles[i].id) && articles[i].state == .cleared {
            articles[i].state = .inbox
            articles[i].clearedAt = nil
            articles[i].readAt = nil
            articles[i].restoredAt = now   // as in restore(_:): wins over the other Macs' cleared record
            restored = true
        }
        guard restored else { return true }
        save()
        let items = TriageItem.items(groups: visibleGroupedInbox, collapsed: collapsedGroupIDs)
        if batch.count == 1, items.contains(where: { $0.cursor == batch[0] }) {
            inboxCursor = batch[0]
        } else if let header = items.first(where: {
            if case .header(_, let first) = $0 { return ids.contains(first) }
            return false
        }) {
            inboxCursor = header.cursor
        } else if let first = items.first(where: { ids.contains($0.cursor) }) {
            inboxCursor = first.cursor
        }
        return true
    }
}
