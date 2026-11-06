import Foundation
import XCTest
@testable import VocabCapture

final class MathSkillSupplementIntegrationTests: XCTestCase {
  private let names: Set<String> = [
    "square-corner-cuts-and-area-differences", "fixed-count-grid-piece-reassembly", "nested-square-size-inventory", "rectangle-staircase-reassembly", "equal-square-diagonal-reassembly", "square-cyclic-midpoint-dissection", "regular-dodecagon-unit-dissection", "integer-lattice-triangle-extrema", "right-isosceles-inscribed-figures", "triangular-lattice-area-dissection", "seven-segment-digit-restoration", "arithmetic-transformations", "column-digit-constraints", "horizontal-digit-constraints",
    "place-value-and-decimals", "sequences-and-number-tables", "counting-by-cases-and-stages",
    "restricted-arrangements", "geometric-cut-and-rearrange", "lattice-polygon-area",
    "rectilinear-area-and-perimeter", "logic-constraint-elimination", "scheduling-and-exchange",
    "finite-game-strategy", "extremal-bounds-and-construction", "finite-state-transformations", "long-division-reconstruction", "digit-rearrangement-multiples", "motion-events-and-periodic-arrivals", "base-height-area-relations", "grid-partition-and-tiling", "repeated-digit-blocks", "lattice-point-area-formula", "combinatorial-symbols-and-ranking", "multiset-and-unlabelled-counting", "magic-and-latin-grid-constraints", "adjacency-colouring-with-inventory", "directed-acyclic-path-counting", "transfer-state-and-conservation", "layered-table-indexing", "translated-table-windows-and-fixed-sum-extrema", "recursive-sequence-cycles-and-windows", "incidence-sum-constraints-and-extrema", "rounded-quotient-iteration", "unequal-group-sums-and-alternating-elimination", "difference-constrained-labels-and-signed-cycles", "additive-towers-and-network-propagation", "absolute-difference-tower-propagation",
  ]

  func testSupplementIsLoadableVersionBoundAndDoesNotInventHumanApproval() throws {
    let catalogue = try MathSkillCatalogue.load()
    let research = try MathTeachingReviewCatalogue.load()
    XCTAssertTrue(names.isSubset(of: Set(catalogue.skills.map(\.name))))
    for skill in catalogue.skills where names.contains(skill.name) {
      let profile = try XCTUnwrap(research.profiles.first { $0.skill_name == skill.name })
      XCTAssertEqual(profile.skill_version, skill.version)
      XCTAssertEqual(profile.skill_sha256, skill.sha256)
      XCTAssertEqual(profile.selection_roles, ["solution"])
      XCTAssertEqual(profile.review_status, "review_required")
      let evidence = research.cases.filter { profile.evidence_case_ids.contains($0.id) }
      XCTAssertTrue(evidence.contains { $0.kind == "positive" })
      XCTAssertTrue(evidence.contains { $0.kind == "confusing_negative" })
      let method = MathTeachingMethod(id: skill.sourceID, versionID: UUID().uuidString,
        title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
      XCTAssertEqual(research.seed(for: method)?.status, "draft")
      // A title alone cannot confer the new method's trusted role or permissions.
      let edited = MathTeachingMethod(id: method.id, versionID: UUID().uuidString,
        title: method.title, category: method.category, instructions: "用户另写的方法", createdAt: Date())
      XCTAssertNil(research.reference(for: edited))
      XCTAssertTrue(MathMethodMatcher.eligibleMethods([edited], question: "四年级，不用方程").isEmpty)
    }
  }

  func testImportAddsSupplementsIdempotentlyAndPreservesEditedAndArchivedMethods() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MathQuestionStore(directory: root)
    let catalogue = try MathSkillCatalogue.load()
    let oldSkills = catalogue.skills.filter { !names.contains($0.name) }
    let oldIDs = Set(oldSkills.map(\.sourceID))
    _ = try await store.importMethods(catalogue.importEntries().filter { oldIDs.contains($0.sourceID) })
    let existing = try await store.methods()
    let custom = try XCTUnwrap(existing.first { $0.title == "平均数问题" })
    let edited = try await store.saveMethod(id: custom.id, title: custom.title,
      category: custom.category, instructions: custom.instructions + "\n用户保留的讲法。")
    let archived = try XCTUnwrap(existing.first { $0.title == "行程问题" })
    try await store.archiveMethod(id: archived.id)
    let first = try await store.importBundledMathSkills(catalogue)
    XCTAssertEqual(first.imported, names.count)
    let second = try await store.importBundledMathSkills(catalogue)
    XCTAssertEqual(second.imported, 0)
    XCTAssertEqual(second.updated, 0)
    let current = try await store.methods()
    XCTAssertTrue(current.contains { $0.id == edited.id && $0.instructions == edited.instructions })
    XCTAssertFalse(current.contains { $0.id == archived.id })
    let supplements = current.filter { method in
      catalogue.skills.contains { names.contains($0.name) && $0.sourceID == method.id }
    }
    XCTAssertEqual(supplements.count, names.count)
    for method in supplements {
      let profile = try await store.skillProfile(versionID: method.versionID)
      XCTAssertNotEqual(profile?.status, "approved")
      let events = try await store.skillLifecycleEvents(versionID: method.versionID)
      XCTAssertFalse(events.contains { $0.decision == "approved" })
    }
    await store.close()
  }
}
