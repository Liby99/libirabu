// Multiple calendars ("documents"): create / switch / remove / rename, plus the read accessors the File
// menu renders. Switching is built on the existing whole-dataset swap — persist the current calendar,
// repoint the store, and reload — with the session state (undo, selection, imported items, caches) reset
// so nothing bleeds from one calendar into the next. Each calendar is disjoint; only one is open at a time.

import Foundation

public extension CalendarEngine {
    /// ── Read accessors (for the File menu) ────────────────────────────────────────────────────────
    var activeCalendar: CalendarMeta? {
        registry.meta(registry.activeId)
    }

    var activeCalendarName: String {
        activeCalendar?.name ?? "Main"
    }

    var allCalendars: [CalendarMeta] {
        registry.all
    }

    /// Calendars you can switch to (for "Recently Opened Calendars ▸"): the recently-opened ones first,
    /// then any others — so a calendar discovered from another device (never opened here) is still reachable.
    var recentCalendars: [CalendarMeta] {
        let active = registry.activeId
        let recent = registry.recents(excluding: active)
        let seen = Set(recent.map(\.id))
        let others = registry.all.filter { $0.id != active && !seen.contains($0.id) }
        return recent + others
    }

    /// "Remove Current" is disabled when this is the only calendar (there must always be one).
    var canRemoveCalendar: Bool {
        registry.all.count > 1
    }

    /// ── Switch ────────────────────────────────────────────────────────────────────────────────────
    /// Open a different calendar: persist the current one, tear down its sync, reset all session state,
    /// then repoint the store and load the target. No-op if it's already active or doesn't exist.
    /// `persistCurrent: false` is used when the current calendar is being deleted (nothing to save).
    func switchCalendar(to id: String, persistCurrent: Bool = true) {
        guard id != registry.activeId, registry.meta(id) != nil else { return }
        commitTxn() // flush any pending edit on the current calendar
        if persistCurrent {
            persistNow()
        }
        stopCloudSync() // detach cloud from the current calendar

        // Reset everything scoped to the current calendar so nothing bleeds across.
        undoStack.removeAll(); redoStack.removeAll(); pendingUndo = nil
        setSelection([], primary: nil)
        imported = ImportedItems() // read-only Apple items belong to the old calendar
        colorPreview = nil; hover = .none; hoveredEventId = nil
        caches = DisplayCaches() // display caches were keyed to the old data

        // Repoint at the target calendar and load it.
        registry.setActive(id)
        store = ItemStore(calendarId: id)
        restoreItemsFromStore()
        migrateAnchors()

        // Re-attach external sources for the NEW calendar (its own Apple selection + iCloud state).
        enableCloudSyncIfEntitled()
        importAppleCalendar()
        onExternalDataChange?() // dismiss any drawer/dialog bound to a now-absent item
        NotificationScheduler.shared.requestResync() // schedule now reflects the NEW calendar's items
        wake()
    }

    /// ── Create ──────────────────────────────────────────────────────────────────────────────────
    /// Create a new empty calendar and switch into it. Returns its id. A blank name falls back to "Untitled".
    @discardableResult
    func createCalendar(named name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = registry.create(name: t.isEmpty ? "Untitled" : t)
        switchCalendar(to: meta.id) // starts item sync for the new zone + registrySync if needed
        registrySync?.upsertCalendar(meta.id) // publish the new calendar to the synced registry
        return meta.id
    }

    /// ── Remove ──────────────────────────────────────────────────────────────────────────────────
    /// Delete the current calendar (and all its data) and switch to the most-recent other one. No-op when
    /// it's the only calendar. The current calendar isn't persisted first — it's being thrown away.
    func removeCurrentCalendar() {
        let list = registry.all
        guard list.count > 1 else { return }
        let doomed = registry.activeId
        let fallback = recentCalendars.first?.id ?? list.first(where: { $0.id != doomed })!.id
        switchCalendar(to: fallback, persistCurrent: false) // stops the doomed calendar's item sync
        CloudSync.deleteZone(calendarId: doomed) // purge its CloudKit zone (all its records)
        registrySync?.removeCalendar(doomed) // drop it from the synced calendar registry
        registry.remove(doomed) // registry entry + local directory
        wake()
    }

    /// ── Rename ──────────────────────────────────────────────────────────────────────────────────
    /// Rename the active calendar. Empty names are rejected.
    func renameCurrentCalendar(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        registry.rename(registry.activeId, to: t)
        registrySync?.upsertCalendar(registry.activeId) // propagate the new name to other devices
        wake()
    }

    /// ── Inbound registry changes (from RegistrySync on another device) ────────────────────────────
    /// Merge a remote calendar-list change: add/rename entries, and remove deleted ones. If the OPEN
    /// calendar was deleted elsewhere, switch to a fallback first (never persist the doomed calendar).
    func applyRemoteCalendars(upserts: [CalendarMeta], deletes: [String]) {
        for m in upserts {
            registry.upsertRemote(m)
        }
        for id in deletes where registry.meta(id) != nil {
            if id == registry.activeId {
                let fallback = allCalendars.first { $0.id != id }?.id ?? registry.create(name: "Main").id
                switchCalendar(to: fallback, persistCurrent: false)
            }
            registry.remove(id)
        }
        wake() // the File menu re-reads the list on next open
    }

    /// ── Cloud teardown (switch/remove) ────────────────────────────────────────────────────────────
    /// Stop syncing the current calendar and detach the cloud layer. In the unsigned dev shell `cloud`
    /// is always nil, so this is a no-op there.
    internal func stopCloudSync() {
        cloud?.stop()
        cloud = nil
        onLocalChange = nil
        syncedState = nil
    }
}
