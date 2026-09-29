// Attachment lifecycle (P3, design §7–8): the sweep deletes only at the intersection of
// UNREFERENCED and PAST THE 7-DAY GRACE (sightings refresh the clock; a young orphan and an
// unparseable stamp both survive), and the `.mgc` backup carries the referenced blobs both
// ways — export packs `files/<sha256>.<ext>` + `attachment` rows, import hash-verifies each
// payload back into the CAS, and a legacy backup without `files/` still imports cleanly.

@testable import CalendarEngine
import XCTest

@MainActor
final class AttachmentLifecycleTests: XCTestCase {
    override func setUp() { super.setUp(); redirectStoreToTemp() }
    override func tearDown() { unsetenv("CC_DEMO_DATADIR"); super.tearDown() }

    // ── The sweep ─────────────────────────────────────────────────────────────────────

    func testSweepReclaimsOldOrphansAndRefreshesSightings() throws {
        let e = CalendarEngine()
        let kept = try e.attachments.importData(Data("kept".utf8), suggestedName: "kept.txt")
        let orphan = try e.attachments.importData(Data("orphan".utf8), suggestedName: "orphan.txt")
        e.setDailyNote("2026-06-02", kept.markdown)
        let keptHash = try XCTUnwrap(e.attachments.resolveHash(forId: kept.id))
        let orphanHash = try XCTUnwrap(e.attachments.resolveHash(forId: orphan.id))
        // Backdate BOTH past the grace window; only the unreferenced one may die.
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        e.attachments.touch(hashes: [keptHash, orphanHash], at: old)

        let now = Date()
        let r = e.sweepAttachments(now: now)
        XCTAssertEqual(r, AttachmentSweepResult(swept: 1, sweptBytes: 6, inGrace: 0, referenced: 1))
        XCTAssertNil(e.attachments.url(forId: orphan.id), "old orphan reclaimed")
        XCTAssertNotNil(e.attachments.url(forId: kept.id), "referenced blob survives any age")
        XCTAssertEqual(e.attachments.meta(forId: kept.id)?.lastReferencedAt,
                       AttachmentStore.stamp(now), "a sighting restarts the grace clock")
    }

    func testSweepSparesYoungOrphans() throws {
        let e = CalendarEngine()
        let orphan = try e.attachments.importData(Data("young".utf8), suggestedName: "young.txt")
        let r = e.sweepAttachments() // imported seconds ago → inside grace
        XCTAssertEqual(r.swept, 0)
        XCTAssertEqual(r.inGrace, 1)
        XCTAssertNotNil(e.attachments.url(forId: orphan.id))
    }

    func testSweepIgnoresGhostsAndBadStamps() throws {
        let e = CalendarEngine()
        // A ghost (token, no local blob) must never crash or count as sweepable.
        e.setDailyNote("2026-06-03", "![@pdf:ghost.pdf](ccfile:00ff00ff00ff00ff)")
        // An orphan whose stamp got corrupted: parse fails → treated as young, NEVER deleted.
        let odd = try e.attachments.importData(Data("odd".utf8), suggestedName: "odd.txt")
        let hash = try XCTUnwrap(e.attachments.resolveHash(forId: odd.id))
        e.attachments.corruptStampForTesting(hash: hash)
        let r = e.sweepAttachments(now: Date().addingTimeInterval(365 * 24 * 3600))
        XCTAssertEqual(r.swept, 0, "unparseable stamp must fail safe")
        XCTAssertEqual(r.inGrace, 1)
        XCTAssertNotNil(e.attachments.url(forId: odd.id))
    }

    // ── Backup round-trip ─────────────────────────────────────────────────────────────

    func testBackupCarriesAttachmentsBothWays() throws {
        let e = CalendarEngine()
        let token = try e.attachments.importData(Data("precious bytes".utf8),
                                                 suggestedName: "precious.txt")
        let hash = try XCTUnwrap(e.attachments.resolveHash(forId: token.id))
        e.setDailyNote("2026-06-02", "keep:\n\(token.markdown)")
        let evId = e.createTimedEvent(year: e.year, month: 6, day: 2, startHour: 9, endHour: 10,
                                      title: "Standup", color: "blue")
        e.setNotes(evId, token.markdown)
        // An orphan does NOT ride along — backups carry what the notes reference.
        _ = try e.attachments.importData(Data("orphan".utf8), suggestedName: "orphan.txt")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bk-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        try e.exportMDC(to: url)

        // The zip layout matches the web contract: one files/ entry + one attachment row.
        let files = try Zipper.read(url)
        let ext = (token.name as NSString).pathExtension
        XCTAssertNotNil(files["files/\(hash).\(ext)"], "\(files.keys.sorted())")
        let db = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(files["database.json"])) as? [String: Any])
        let rows = try XCTUnwrap(db["attachment"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1, "referenced blob only — the orphan stays home")
        XCTAssertEqual(rows.first?["sha256"] as? String, hash)
        XCTAssertEqual(rows.first?["filename"] as? String, "precious.txt")

        // Wipe the blob locally, then restore: the note AND the payload come back verified.
        e.attachments.remove(hash: hash)
        XCTAssertNil(e.attachments.url(forId: token.id))
        try e.importMDC(from: url)
        XCTAssertNotNil(e.attachments.url(forId: token.id), "payload landed back in the CAS")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(e.attachments.url(forId: token.id))),
                       Data("precious bytes".utf8))
        XCTAssertTrue(e.items.dailyNotes["2026-06-02"]?.contains(token.markdown) == true)
    }

    func testLegacyBackupWithoutFilesImportsCleanly() throws {
        let e = CalendarEngine()
        e.setDailyNote("2026-06-02", "plain old note")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-\(UUID().uuidString).mgc")
        defer { try? FileManager.default.removeItem(at: url) }
        // encode() with no attachments = exactly the pre-P3 layout (files: 0, empty table).
        try Zipper.write(MDCBackup.encode(e.exportState(), exportedAt: Date()), to: url)
        try e.importMDC(from: url)
        XCTAssertEqual(e.items.dailyNotes["2026-06-02"], "plain old note")
        XCTAssertTrue(MDCBackup.decodeAttachments(try Zipper.read(url)).isEmpty)
    }

    func testTamperedBackupPayloadIsRejected() throws {
        let e = CalendarEngine()
        XCTAssertFalse(e.attachments.adoptData(Data("not the bytes".utf8),
                                               declaredHash: String(repeating: "ab", count: 32),
                                               name: "evil.txt", uti: "public.plain-text"),
                       "a payload that doesn't hash to its declaration never enters the CAS")
        XCTAssertTrue(e.attachments.allEntries().isEmpty)
    }
}
