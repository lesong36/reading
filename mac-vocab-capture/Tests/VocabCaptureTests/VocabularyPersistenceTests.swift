import XCTest
@testable import VocabCapture

final class VocabularyPersistenceTests: XCTestCase {
  private let definition = DictionaryResult(lemma: "", meaning: "词义", partOfSpeech: "n.", pronunciation: "", note: "")

  func testCorruptionCannotBeOverwrittenByNextSave() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("vocabulary.json")
    let broken = Data("{ damaged vocabulary".utf8)
    try broken.write(to: file)
    let store = VocabularyStore(directory: directory)
    do { _ = try await store.add(word: "new", dictionary: definition, context: "New context."); XCTFail("Must reject writes to a corrupt store") } catch {}
    XCTAssertEqual(try Data(contentsOf: file), broken)
  }

  func testCanonicalDuplicateDoesNotCreateAnotherEntry() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    _ = try await store.add(word: " hello ", dictionary: definition, context: "Hello there.")
    _ = try await store.add(word: "HELLO", dictionary: definition, context: "Hello there.")
    let entries = await store.all()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.word, "hello")
  }

  func testLegacyBytesRemainUnchangedUntilExplicitBinding() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = VocabularyEntry(word: "legacy", dictionary: definition, context: "Old context.")
    let data = try JSONEncoder().encode([original])
    let root = directory.appendingPathComponent("vocabulary.json")
    try data.write(to: root)
    let store = VocabularyStore(directory: directory)
    let initialBatch = await store.syncBatch()
    XCTAssertNil(initialBatch)
    _ = try await store.add(word: "inbox", dictionary: definition, context: "New context.")
    XCTAssertEqual(try Data(contentsOf: root), data)
    try await store.activateAccount(userID: "account-A")
    let beforeBinding = await store.all()
    XCTAssertTrue(beforeBinding.isEmpty)
    try await store.adoptUnassignedEntries(into: "account-A")
    let adopted = await store.all()
    XCTAssertEqual(Set(adopted.map(\.word)), ["legacy", "inbox"])
    XCTAssertEqual(try Data(contentsOf: root), data)
    let batch = await store.syncBatch()
    XCTAssertEqual(batch?.operations.count, 2)
    try await store.activateAccount(userID: nil)
    let inbox = await store.all()
    XCTAssertTrue(inbox.isEmpty, "Legacy receipt must prevent a second implicit import")
  }

  func testAccountsNeverShareLibrariesAndOutboxSurvivesRestart() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "account-A")
    _ = try await store.add(word: "alpha", dictionary: definition, context: "Alpha context.")
    let capturedBatch9 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch9)
    try await store.activateAccount(userID: "account-B")
    let other = await store.all()
    XCTAssertTrue(other.isEmpty)
    do {
      try await store.acknowledgeSync(vocabulary: [], revision: 1,
        acknowledgedOperationIDs: batch.operations.map(\.operationID), basedOn: batch)
      XCTFail("Old account cannot mutate current store")
    } catch {}
    let reopened = VocabularyStore(directory: directory)
    try await reopened.activateAccount(userID: "account-A")
    let capturedBatch8 = await reopened.syncBatch()
    let replay = try XCTUnwrap(capturedBatch8)
    XCTAssertEqual(replay.operations, batch.operations, "Operation IDs must survive offline restart")
    XCTAssertEqual(replay.baseRevision, 0)
  }

  func testSwitchAwayAndBackRejectsOldRequestGeneration() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    let capturedBatch7 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch7)
    try await store.activateAccount(userID: "B")
    try await store.activateAccount(userID: "A")
    do {
      try await store.acknowledgeSync(vocabulary: [], revision: 1, acknowledgedOperationIDs: [], basedOn: batch)
      XCTFail("A stale request must not become valid after switching back")
    } catch {}
  }

  func testAcknowledgementPreservesSavesDuringRequestAndPendingReceipt() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    let old = try await store.add(word: "old", dictionary: definition, context: "Old context.")
    let capturedBatch6 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch6)
    _ = try await store.add(word: "new", dictionary: definition, context: "New context.")
    try await store.acknowledgeSync(vocabulary: [old], revision: 4,
      acknowledgedOperationIDs: batch.operations.map(\.operationID), basedOn: batch)
    let capturedBatch5 = await store.syncBatch()
    let current = try XCTUnwrap(capturedBatch5)
    XCTAssertEqual(current.operations.map(\.wordKey), ["new"])
    XCTAssertEqual(current.baseRevision, 4)
    let reopened = VocabularyStore(directory: directory)
    try await reopened.activateAccount(userID: "A")
    let entries = await reopened.all()
    XCTAssertEqual(Set(entries.map(\.word)), ["new", "old"])
    let replay = await reopened.syncBatch()
    XCTAssertEqual(replay?.operations, current.operations)
  }

  func testUnknownReceiptDoesNotDiscardPending() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "word", dictionary: definition, context: "Context.")
    let capturedBatch4 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch4)
    do {
      try await store.acknowledgeSync(vocabulary: [], revision: 1,
        acknowledgedOperationIDs: ["unknown"], basedOn: batch)
      XCTFail("Receipt must be a subset of submitted operations")
    } catch {}
    let pending = await store.pendingCount()
    XCTAssertEqual(pending, 1)
  }

  func testReaddingDeletedWordProducesVersionedRestore() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    let capturedBatch3 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch3)
    try await store.acknowledgeSync(vocabulary: [], revision: 7, acknowledgedOperationIDs: [], basedOn: batch,
      tombstones: [VocabularyTombstone(wordKey: "again", version: 7, deletedAt: nil)])
    _ = try await store.add(word: " AGAIN ", dictionary: definition, context: "Again context.")
    let capturedBatch2 = await store.syncBatch()
    let restore = try XCTUnwrap(capturedBatch2).operations.first
    XCTAssertEqual(restore?.kind, .restore)
    XCTAssertEqual(restore?.wordKey, "again")
    XCTAssertEqual(restore?.baseVersion, 7)
  }

  func testFailedAcknowledgementRollsBackEntriesAndOutbox() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "retain", dictionary: definition, context: "Retain context.")
    let capturedBatch1 = await store.syncBatch()
    let batch = try XCTUnwrap(capturedBatch1)
    let state = await store.status()
    try FileManager.default.removeItem(at: state.fileURL)
    try FileManager.default.createDirectory(at: state.fileURL, withIntermediateDirectories: true)
    do {
      try await store.acknowledgeSync(vocabulary: [], revision: 1,
        acknowledgedOperationIDs: batch.operations.map(\.operationID), basedOn: batch)
      XCTFail("Disk failure must reject acknowledgement")
    } catch {}
    let entries = await store.all()
    let pending = await store.syncBatch()
    XCTAssertEqual(entries.map(\.word), ["retain"])
    XCTAssertEqual(pending?.operations, batch.operations)
    XCTAssertEqual(pending?.baseRevision, 0)
  }

  func testCorruptStoreCanBeExportedAndRecoveredFromBackup() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    _ = try await store.add(word: "safe", dictionary: definition, context: "Safe context.")
    _ = try await store.add(word: "later", dictionary: definition, context: "Later context.")
    let state = await store.status()
    let corrupt = Data("broken".utf8)
    try corrupt.write(to: state.fileURL)
    let reopened = VocabularyStore(directory: directory)
    let blocked = await reopened.status()
    XCTAssertNotNil(blocked.issue)
    let export = directory.appendingPathComponent("export.json")
    try await reopened.exportOriginal(to: export)
    XCTAssertEqual(try Data(contentsOf: export), corrupt)
    try await reopened.restoreBackup(number: 1)
    let entries = await reopened.all()
    let recovered = await reopened.status()
    XCTAssertEqual(entries.map(\.word), ["safe"])
    XCTAssertNil(recovered.issue)
  }

  func testUnsupportedEnvelopeAndAccountMismatchCannotBeOverwritten() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("vocabulary.json")
    var future = VocabularyEnvelope()
    future.schemaVersion = 99
    let data = try JSONEncoder().encode(future)
    try data.write(to: file)
    let store = VocabularyStore(directory: directory)
    do { _ = try await store.add(word: "new", dictionary: definition, context: "Context."); XCTFail("Unsupported version must block write") } catch {}
    XCTAssertEqual(try Data(contentsOf: file), data)
    future.schemaVersion = 1
    future.userID = "wrong-account"
    let mismatched = try JSONEncoder().encode(future)
    try mismatched.write(to: file)
    let other = VocabularyStore(directory: directory)
    let status = await other.status()
    XCTAssertNotNil(status.issue)
    XCTAssertEqual(try Data(contentsOf: file), mismatched)
  }

  func testInterruptedBindingResumesWithoutReuploadAfterTargetWasAcknowledged() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = BindingFailureFileManager()
    manager.sourcePath = directory.appendingPathComponent("vocabulary.json").path
    let store = VocabularyStore(fileManager: manager, directory: directory)
    _ = try await store.add(word: "once", dictionary: definition, context: "Once only.")
    // Archive and prepare succeed; target commits; receipt's third source copy fails.
    manager.failOnCopy = 3
    do { try await store.adoptUnassignedEntries(into: "A"); XCTFail("Expected interrupted receipt") } catch {}
    let prepared = try JSONDecoder().decode(VocabularyEnvelope.self,
      from: Data(contentsOf: directory.appendingPathComponent("vocabulary.json")))
    let operation = try XCTUnwrap(prepared.adoption?.operations.first)
    let reopened = VocabularyStore(directory: directory)
    do { _ = try await reopened.add(word: "unsafe", dictionary: definition, context: "Context."); XCTFail("Cannot alter an interrupted source snapshot") } catch {}
    do { try await reopened.adoptUnassignedEntries(into: "B"); XCTFail("Cannot silently change the binding target") } catch {}
    try await reopened.activateAccount(userID: "A")
    let captured = await reopened.syncBatch()
    let batch = try XCTUnwrap(captured)
    XCTAssertEqual(batch.operations.first?.operationID, operation.operationID)
    let current = await reopened.all()
    try await reopened.acknowledgeSync(vocabulary: current, revision: 1,
      acknowledgedOperationIDs: batch.operations.map(\.operationID), basedOn: batch)
    try await reopened.adoptUnassignedEntries(into: "A")
    let pending = await reopened.pendingCount()
    XCTAssertEqual(pending, 0, "Resuming the receipt cannot queue an already imported and uploaded operation")
    try await reopened.activateAccount(userID: nil)
    let cleared = await reopened.all()
    XCTAssertTrue(cleared.isEmpty)
  }

  func testBindingKeepsTargetEntryWhenCanonicalKeysCollide() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    _ = try await store.add(word: "Word", dictionary: definition, context: "Unsigned original.")
    let root = directory.appendingPathComponent("vocabulary.json")
    let originalBytes = try Data(contentsOf: root)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "word", dictionary: definition, context: "Target original.")
    try await store.adoptUnassignedEntries(into: "A")
    let entries = await store.all()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.sourceContext, "Target original.")
    let pending = await store.pendingCount()
    XCTAssertEqual(pending, 1)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let archive = try XCTUnwrap(files.first { $0.lastPathComponent.contains("before-binding-") })
    XCTAssertEqual(try Data(contentsOf: archive), originalBytes)
  }

  func testMissingBackupDoesNotRecoverAnEmptyLibrary() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    _ = try await store.add(word: "keep", dictionary: definition, context: "Keep context.")
    do { try await store.restoreBackup(number: 1); XCTFail("Missing backup must fail") } catch {}
    let entries = await store.all()
    XCTAssertEqual(entries.map(\.word), ["keep"])
  }

  func testLegacyArrayBackupRestoresUnassignedDataWithoutUploading() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("vocabulary.json")
    let broken = Data("broken legacy".utf8)
    try broken.write(to: root)
    let data = try JSONEncoder().encode([VocabularyEntry(word: "legacy", dictionary: definition, context: "Context.")])
    try data.write(to: root.appendingPathExtension("backup1"))
    let store = VocabularyStore(directory: directory)
    try await store.restoreBackup(number: 1)
    let entries = await store.all()
    let batch = await store.syncBatch()
    XCTAssertEqual(entries.map(\.word), ["legacy"])
    XCTAssertNil(batch)
    XCTAssertEqual(try Data(contentsOf: root), data)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let preservation = try XCTUnwrap(files.first { $0.lastPathComponent.contains("recovery-") })
    XCTAssertEqual(try Data(contentsOf: preservation), broken)
  }

  func testBackupsRemainBoundedAndContainPriorCompleteSnapshots() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    for index in 1...5 {
      _ = try await store.add(word: "word\(index)", dictionary: definition, context: "Context.")
    }
    let status = await store.status()
    XCTAssertEqual(status.backupURLs.count, 3)
    let oldest = try JSONDecoder().decode(VocabularyEnvelope.self,
      from: Data(contentsOf: status.fileURL.appendingPathExtension("backup3")))
    XCTAssertEqual(oldest.entries.count, 2)
    XCTAssertEqual(oldest.pending.count, 2)
  }

  func testExhaustedRevisionCannotCrashOrOverwriteTheStore() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var envelope = VocabularyEnvelope()
    envelope.localRevision = Int64.max
    let bytes = try JSONEncoder().encode(envelope)
    let root = directory.appendingPathComponent("vocabulary.json")
    try bytes.write(to: root)
    let store = VocabularyStore(directory: directory)
    do { _ = try await store.add(word: "new", dictionary: definition, context: "Context."); XCTFail("Must reject exhausted revision") } catch {}
    XCTAssertEqual(try Data(contentsOf: root), bytes)
    let entries = await store.all()
    XCTAssertTrue(entries.isEmpty)
  }

  func testAdoptCloudResolvesOnlyChosenKeysAndPreservesOtherPending() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "conflict", dictionary: definition, context: "Local conflict.")
    _ = try await store.add(word: "keep", dictionary: definition, context: "Unrelated pending.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    let before = await store.status()
    let originalBytes = try Data(contentsOf: before.fileURL)
    var cloud = VocabularyEntry(word: "conflict", dictionary: definition, context: "Cloud correction.")
    cloud.cloudVersion = 4
    try await store.resolveConflicts(wordKeys: [" CONFLICT "], cloudVocabulary: [cloud], cloudRevision: 4,
      tombstones: [], strategy: .adoptCloud, basedOn: batch)
    let entries = await store.all()
    XCTAssertEqual(entries.first { $0.word == "conflict" }?.sourceContext, "Cloud correction.")
    XCTAssertEqual(entries.first { $0.word == "keep" }?.sourceContext, "Unrelated pending.")
    let resolved = await store.syncBatch()
    XCTAssertEqual(resolved?.operations, batch.operations.filter { $0.wordKey == "keep" })
    XCTAssertEqual(resolved?.baseRevision, 4)
    let files = try FileManager.default.contentsOfDirectory(at: before.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    let archive = try XCTUnwrap(files.first { $0.lastPathComponent.contains("before-conflict-") })
    XCTAssertEqual(try Data(contentsOf: archive), originalBytes)
  }

  func testResubmitLocalUsesFreshCloudVersionAndNewOperationID() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "conflict", dictionary: definition, context: "Local choice.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    var cloud = VocabularyEntry(word: "conflict", dictionary: definition, context: "Cloud choice.")
    cloud.cloudVersion = 9
    try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [cloud], cloudRevision: 10,
      tombstones: [], strategy: .resubmitLocal, basedOn: batch)
    let resolved = await store.syncBatch()
    let operation = try XCTUnwrap(resolved?.operations.first)
    XCTAssertEqual(operation.kind, .upsert)
    XCTAssertEqual(operation.baseVersion, 9)
    XCTAssertEqual(operation.entry?.cloudVersion, 9)
    XCTAssertEqual(operation.entry?.sourceContext, "Local choice.")
    XCTAssertNotEqual(operation.operationID, batch.operations.first?.operationID)
    let reopened = VocabularyStore(directory: directory)
    try await reopened.activateAccount(userID: "A")
    let persistent = await reopened.syncBatch()
    XCTAssertEqual(persistent?.operations, resolved?.operations)
  }

  func testExplicitLocalChoiceRestoresAtFreshTombstoneVersion() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "removed", dictionary: definition, context: "Restore me.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    try await store.resolveConflicts(wordKeys: ["removed"], cloudVocabulary: [], cloudRevision: 7,
      tombstones: [VocabularyTombstone(wordKey: "removed", version: 7, deletedAt: nil)],
      strategy: .resubmitLocal, basedOn: batch)
    let resolved = await store.syncBatch()
    XCTAssertEqual(resolved?.operations.first?.kind, .restore)
    XCTAssertEqual(resolved?.operations.first?.baseVersion, 7)
    XCTAssertNotEqual(resolved?.operations.first?.operationID, batch.operations.first?.operationID)
  }

  func testCloudDeletionChoiceRemovesOnlyConflictedLocalWord() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "removed", dictionary: definition, context: "Context.")
    _ = try await store.add(word: "keep", dictionary: definition, context: "Context.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    try await store.resolveConflicts(wordKeys: ["removed"], cloudVocabulary: [], cloudRevision: 7,
      tombstones: [VocabularyTombstone(wordKey: "removed", version: 7, deletedAt: nil)],
      strategy: .adoptCloud, basedOn: batch)
    let entries = await store.all()
    let resolved = await store.syncBatch()
    XCTAssertEqual(entries.map(\.word), ["keep"])
    XCTAssertEqual(resolved?.operations.map(\.wordKey), ["keep"])
  }

  func testConflictChoiceCannotUseStaleAccountOrAlreadyReplacedOperation() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "conflict", dictionary: definition, context: "Context.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [], cloudRevision: 1,
      tombstones: [], strategy: .resubmitLocal, basedOn: batch)
    let resolved = await store.syncBatch()
    do {
      try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [], cloudRevision: 2,
        tombstones: [], strategy: .adoptCloud, basedOn: batch)
      XCTFail("Old conflict choice cannot clear a newly generated operation")
    } catch {}
    let after = await store.syncBatch()
    XCTAssertEqual(after?.operations, resolved?.operations)
    try await store.activateAccount(userID: "B")
    do {
      try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [], cloudRevision: 2,
        tombstones: [], strategy: .adoptCloud, basedOn: batch)
      XCTFail("Old account choice cannot mutate another account")
    } catch {}
    let other = await store.all()
    XCTAssertTrue(other.isEmpty)
  }

  func testFailedConflictArchiveDoesNotChangeEntriesOrQueue() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = BindingFailureFileManager()
    let store = VocabularyStore(fileManager: manager, directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "conflict", dictionary: definition, context: "Original.")
    let state = await store.status()
    manager.sourcePath = state.fileURL.path
    manager.failOnCopy = 1
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    do {
      try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [], cloudRevision: 2,
        tombstones: [], strategy: .adoptCloud, basedOn: batch)
      XCTFail("Cannot discard a local conflict without preserving its original bytes")
    } catch {}
    let pending = await store.syncBatch()
    let entries = await store.all()
    XCTAssertEqual(pending?.operations, batch.operations)
    XCTAssertEqual(pending?.baseRevision, batch.baseRevision)
    XCTAssertEqual(entries.first?.sourceContext, "Original.")
  }

  func testConflictResolutionRejectsInvalidCloudOrTombstoneVersions() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    _ = try await store.add(word: "conflict", dictionary: definition, context: "Original.")
    let captured = await store.syncBatch()
    let batch = try XCTUnwrap(captured)
    let missingVersion = VocabularyEntry(word: "conflict", dictionary: definition, context: "Invalid remote.")
    do {
      try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [missingVersion], cloudRevision: 0,
        tombstones: [], strategy: .resubmitLocal, basedOn: batch)
      XCTFail("An existing cloud word must carry a valid version")
    } catch {}
    do {
      try await store.resolveConflicts(wordKeys: ["conflict"], cloudVocabulary: [], cloudRevision: 2,
        tombstones: [VocabularyTombstone(wordKey: "conflict", version: -1, deletedAt: nil)],
        strategy: .resubmitLocal, basedOn: batch)
      XCTFail("Invalid tombstone cannot authorize restoration")
    } catch {}
    let current = await store.syncBatch()
    XCTAssertEqual(current?.operations, batch.operations)
  }

  func testLocalSaveRejectsAccountSwitchIncludingReturnToOriginalAccount() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    let originalScope = await store.writeScope()
    for user in ["B", "A"] {
      try await store.activateAccount(userID: user)
      do {
        _ = try await store.add(word: "private-fixture", dictionary: definition,
          context: "Original account fixture.", scope: originalScope)
        XCTFail("A delayed save must not move across account generations")
      } catch VocabularyPersistenceError.accountChanged { }
      let entries = await store.all()
      XCTAssertTrue(entries.isEmpty)
    }
    let freshScope = await store.writeScope()
    _ = try await store.add(word: "current-fixture", dictionary: definition, context: "Current.", scope: freshScope)
    let entries = await store.all()
    XCTAssertEqual(entries.map(\.word), ["current-fixture"])
  }

  func testLargeDurableQueueIsAcknowledgedInServerSizedBatches() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = VocabularyStore(directory: directory)
    try await store.activateAccount(userID: "A")
    let path = await store.status().fileURL
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entries = (0..<501).map { VocabularyEntry(word: "fixture-\($0)", dictionary: definition, context: "Public fixture.") }
    var envelope = VocabularyEnvelope(userID: "A")
    envelope.entries = entries
    envelope.pending = entries.map { VocabularyMutation(operationID: UUID().uuidString,
      kind: .upsert, wordKey: VocabularyEntry.canonicalWordKey($0.word), entry: $0, baseVersion: nil) }
    try JSONEncoder().encode(envelope).write(to: path, options: .atomic)
    try await store.activateAccount(userID: "A")
    let captured = await store.syncBatch()
    let first = try XCTUnwrap(captured)
    XCTAssertEqual(first.operations.count, 500)
    try await store.acknowledgeSync(vocabulary: Array(entries.prefix(500)), revision: 1,
      acknowledgedOperationIDs: first.operations.map(\.operationID), basedOn: first)
    let second = await store.syncBatch()
    let all = await store.all()
    XCTAssertEqual(second?.operations.count, 1)
    XCTAssertEqual(all.count, 501)
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private final class BindingFailureFileManager: FileManager, @unchecked Sendable {
  var sourcePath = ""
  var failOnCopy = Int.max
  private var sourceCopies = 0
  override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
    if sourceURL.path == sourcePath {
      sourceCopies += 1
      if sourceCopies == failOnCopy { throw CocoaError(.fileWriteNoPermission) }
    }
    try super.copyItem(at: sourceURL, to: destinationURL)
  }
}
