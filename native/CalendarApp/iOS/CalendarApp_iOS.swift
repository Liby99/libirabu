// The iPhone app shell.
//
// The real semantic-zoom calendar UI (CalendarUI) is AppKit-bound and hasn't been ported to
// UIKit yet — that's the rendering track. This target's job is the OTHER half: prove the
// CloudKit data layer works cross-device. It hosts a shared CalendarEngine (which self-starts
// CKSyncEngine sync because an iOS build is always entitled) and a plain SwiftUI harness that
// lists the synced items and can edit them, so a change here shows up on the Mac and vice versa.
//
// When the UIKit renderer lands, swap SyncHarnessView for it — the engine + sync are already here.

import SwiftUI
import CalendarEngine

@main
struct CalendarPhoneApp: App {
    // One engine for the process. Constructing it kicks off CloudKit sync (see
    // CalendarEngine.enableCloudSyncIfEntitled → CloudSync.startIfAccountAvailable).
    @State private var engine = CalendarEngine()

    var body: some Scene {
        WindowGroup {
            SyncHarnessView(engine: engine)
        }
    }
}
