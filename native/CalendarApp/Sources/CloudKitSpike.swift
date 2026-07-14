// Phase-0 de-risk: prove the CloudKit plumbing (entitlements, signing, container,
// account) with a single write→read round-trip against the private database.
//
// This is throwaway scaffolding — it validates that sync CAN work before we build
// the real CKSyncEngine layer. Trigger it from the "Debug ▸ Run CloudKit
// Round-Trip" menu item; the result shows in an alert and the Xcode console.

import CloudKit
import AppKit

enum CloudKitSpike {
    /// Must match the container in CalendarApp.entitlements.
    static let containerID = "iCloud.dev.libirabu.calendar"

    static func run() { Task { await runAsync() } }

    @MainActor
    static func runAsync() async {
        var log: [String] = []
        func note(_ s: String) { print("[CKSpike] \(s)"); log.append(s) }

        let container = CKContainer(identifier: containerID)
        let db = container.privateCloudDatabase

        // 1) Account must be signed in and available.
        do {
            let status = try await container.accountStatus()
            note("accountStatus = \(describe(status))")
            guard status == .available else {
                finish(false, "iCloud account not available. Sign into iCloud in System Settings, then retry.", log)
                return
            }
        } catch {
            finish(false, "accountStatus failed: \(error.localizedDescription)", log)
            return
        }

        // 2) Write one record to the private DB (schema auto-creates in Development).
        let id = CKRecord.ID(recordName: "spike-roundtrip")
        let rec = CKRecord(recordType: "SpikePing", recordID: id)
        let host = Host.current().localizedName ?? "this device"
        rec["message"] = "hello from \(host)" as NSString
        rec["stamp"] = Date() as NSDate
        do {
            let saved = try await db.save(rec)
            note("saved \(saved.recordID.recordName)")
        } catch {
            finish(false, "save failed: \(error.localizedDescription)", log)
            return
        }

        // 3) Read it back to confirm the round-trip.
        do {
            let fetched = try await db.record(for: id)
            let msg = (fetched["message"] as? String) ?? "<nil>"
            note("fetched message = \"\(msg)\"")
            finish(true, "Record wrote to and read from the CloudKit private database.\nmessage = \"\(msg)\"\n\nCheck it at icloud.developer.apple.com → CloudKit Database → SpikePing.", log)
        } catch {
            finish(false, "fetch failed: \(error.localizedDescription)", log)
        }
    }

    @MainActor
    private static func finish(_ ok: Bool, _ summary: String, _ log: [String]) {
        print("[CKSpike] \(ok ? "PASS" : "FAIL"): \(summary)")
        let alert = NSAlert()
        alert.messageText = ok ? "CloudKit Round-Trip: PASS ✅" : "CloudKit Round-Trip: FAIL ❌"
        alert.informativeText = summary + "\n\n— steps —\n" + log.joined(separator: "\n")
        alert.alertStyle = ok ? .informational : .warning
        alert.runModal()
    }

    private static func describe(_ s: CKAccountStatus) -> String {
        switch s {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}
