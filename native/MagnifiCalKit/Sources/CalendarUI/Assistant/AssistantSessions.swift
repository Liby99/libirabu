// The AI window's session POOL: one live AssistantState per active conversation, so switching
// chats never cancels a run. The outgoing session keeps thinking in the pool (the sidebar's
// spinner), its answer persists to the shared store (the unread dot), and re-selecting it
// rebinds the SAME live session — typing bubble, queued messages and all. Idle sessions are
// pruned; their content lives in the store. The quick callout remains its own separate session
// (see AssistantState's peer-persist refresh for how the two stay in sync on one conversation).

import CalendarEngine
import SwiftUI

@Observable @MainActor
public final class AssistantSessions {
    public let store: ConversationStore
    /// The session the window is displaying. Always a pool member.
    public private(set) var current: AssistantState
    private var pool: [AssistantState]

    /// The shared calendar engine — applied to every pool session, present and future.
    public var engine: CalendarEngine? {
        didSet {
            for s in pool {
                s.engine = engine
            }
        }
    }

    public init(store: ConversationStore) {
        self.store = store
        let first = AssistantState(store: store)
        current = first
        pool = [first]
    }

    /// Switch the window to `id` (nil = a fresh chat) WITHOUT cancelling the outgoing run: a
    /// busy outgoing session stays pooled and keeps executing; the target reuses its live
    /// pooled session when one exists (mid-run transcript intact), else loads from the store.
    public func select(_ id: UUID?) {
        guard id == nil || id != current.currentId else { return }
        current.persistNow()
        if let id, let live = pool.first(where: { $0.currentId == id }) {
            current = live
        } else {
            let s = AssistantState(store: store)
            s.engine = engine
            if let id {
                s.selectConversation(id)
            }
            pool.append(s)
            current = s
        }
        prune()
    }

    /// New Chat — a fresh empty session (any outgoing run keeps going in the pool).
    public func newChat() {
        select(nil)
        current.requestInputFocus()
    }

    public func delete(_ id: UUID) {
        if let s = pool.first(where: { $0.currentId == id }), s !== current {
            s.abandon() // hard cancel — no flush/persist into a conversation being deleted
            pool.removeAll { $0 === s }
        }
        current.deleteConversation(id) // store removal (+ clears the transcript if current)
    }

    /// Sidebar spinner: a pool session is actively answering in this conversation.
    public func isRunning(_ id: UUID) -> Bool {
        pool.contains { $0.currentId == id && $0.busy }
    }

    /// Drop idle non-current sessions — nothing live to lose; the store has their content.
    private func prune() {
        pool.removeAll { s in
            s !== current && !s.busy && !s.messages.contains(where: { $0.queued })
        }
    }
}
