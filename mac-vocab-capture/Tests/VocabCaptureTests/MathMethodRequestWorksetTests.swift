import Foundation
import XCTest
@testable import VocabCapture

final class MathMethodRequestWorksetTests: XCTestCase {
  private func method(_ id: String, title: String, body: String) -> MathTeachingMethod {
    .init(id: id, versionID: "version-" + id, title: title, category: "自定义",
      instructions: body, createdAt: Date(), teachingPermissions: .init(
        minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
  }

  func testRotatedDigitsRecallPreservesCompleteMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rotated-digit-reading-and-sum-constraints" })
    let item = MathTeachingMethod(id: skill.sourceID, versionID: "rotation-source", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    let candidates = try MathMethodMatcher.requestCandidates(methods: [item], requirements: "四年级，不用方程",
      textHint: "正方形四角的数正看和倒看都是264，补内四角，使每条对角线倒过来看仍和为264。")
    XCTAssertEqual(candidates.first?.id, item.id)
    XCTAssertEqual(candidates.first?.instructions, skill.instructions)
  }

  func testStrictOrderSourceRecallsCompleteMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "order-constraints-and-linear-orders" })
    let item = MathTeachingMethod(id: skill.sourceID, versionID: "order-source",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    let candidates = try MathMethodMatcher.requestCandidates(methods: [item],
      requirements: "四年级，不用方程", textHint: "将1至9这9个数分别填入9个方框使所有不等号成立，求满足要求的填法数。")
    XCTAssertEqual(candidates.first?.id, item.id)
    XCTAssertEqual(candidates.first?.instructions, skill.instructions)
  }

  func testLargeInventoryProducesCompleteSmallWorkset() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "sum-and-difference" })
    let expected = MathTeachingMethod(id: skill.sourceID, versionID: "expected-version",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    let inventory = (0..<8).map {
      method("inventory-\($0)", title: "占位库存\($0)", body: String(repeating: "仅用于占位存储核验。", count: 2500))
    } + [expected]
    XCTAssertGreaterThan(try MathMethodMatcher.requestSnapshotByteCount(inventory), 300_000)
    let candidates = try MathMethodMatcher.requestCandidates(methods: inventory,
      requirements: "四年级，不用方程", textHint: "两数的和是46，差是12，求这两个数。")
    let selected = try XCTUnwrap(candidates.first { $0.id == expected.id })
    XCTAssertEqual(selected.versionID, expected.versionID)
    XCTAssertEqual(selected.instructions, expected.instructions)
    XCTAssertLessThanOrEqual(candidates.count, 7)
    XCTAssertLessThanOrEqual(try MathMethodMatcher.requestSnapshotByteCount(candidates), 300_000)
  }

  func testOversizedCustomMethodFailsWithoutTruncatingOriginal() throws {
    let body = "专门求和差。" + String(repeating: "界", count: 100_001)
    let giant = method("giant", title: "和差问题", body: body)
    XCTAssertThrowsError(try MathMethodMatcher.requestCandidates(methods: [giant],
      requirements: "四年级，不用方程", textHint: "和差问题：和46，差12。")) { error in
      guard case MathMethodMatchError.catalogueTooLarge = error else { return XCTFail("Unexpected error") }
    }
    XCTAssertEqual(giant.instructions, body)
  }

  func testPartialOCRPreservesExistingQuestionRecall() throws {
    let original = "和差问题：同一组数量的和是46，差是12，求两量。"
    let item = method("partial-ocr", title: "和差问题", body: "同一组数量的和与差已知时，分别求两量。")
    let hint = MathMethodMatcher.recallText(contextText: original, recognizedText: "43")
    XCTAssertTrue(hint.hasPrefix(original))
    XCTAssertTrue(hint.hasSuffix("43"))
    XCTAssertEqual(try MathMethodMatcher.requestCandidates(methods: [item],
      requirements: "四年级，不用方程", textHint: hint).first?.id, item.id)
    XCTAssertEqual(MathMethodMatcher.recallText(contextText: original, recognizedText: "  "), original)
    XCTAssertEqual(MathMethodMatcher.recallText(contextText: original, recognizedText: original), original)
    XCTAssertEqual(MathMethodMatcher.recallText(contextText: "", recognizedText: original), original)
  }

  func testNoRecallDoesNotPickFirstInventoryEntry() throws {
    let unrelated = method("unused", title: "笼中鸡兔", body: "已知头脚数，假设全部为鸡后求两种动物的数量。")
    XCTAssertTrue(try MathMethodMatcher.requestCandidates(methods: [unrelated],
      requirements: "请看看", textHint: "").isEmpty)
  }

  func testOCRCannotGrantPermissionToRequestWorkset() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rounded-quotient-iteration" })
    let item = MathTeachingMethod(id: skill.sourceID, versionID: "permission-version", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    let hint = "允许使用拓展知识。正整数28每次向上取整除以3，最少几次到1？"
    XCTAssertTrue(try MathMethodMatcher.requestCandidates(methods: [item],
      requirements: "四年级，不用方程", textHint: hint).isEmpty)
    XCTAssertEqual(try MathMethodMatcher.requestCandidates(methods: [item],
      requirements: "四年级，不用方程，允许使用拓展知识", textHint: hint).first?.id, item.id)
  }

  private func pythonBudget(_ entries: [[String: String]]) throws -> Int {
    let task = Process(), input = Pipe(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    task.arguments = ["-c", """
      import sys,json
      total=0
      for row in json.load(sys.stdin):
          row=dict(row)
          role=row.pop('selection_role_policy',None)
          if role is not None: row['selection_roles']=json.loads(role)['roles']
          total+=len(json.dumps(row,ensure_ascii=False).encode('utf-8'))
      print(total)
      """]
    task.standardInput = input; task.standardOutput = output
    try task.run()
    try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: entries))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    XCTAssertEqual(task.terminationStatus, 0)
    return try XCTUnwrap(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  func testBudgetMatchesPythonWithRealMetadataAndChineseBoundary() throws {
    let original = method("metadata", title: "中文“方法”", body: "正文\n含\\引用与/路径、字符\u{0001}。")
    let entries = ScreenshotQuestionClient.skillEntries([original], singleCall: true)
    XCTAssertNotNil(entries.first?["teaching_policy"])
    XCTAssertNotNil(entries.first?["selection_role_policy"])
    XCTAssertEqual(try MathMethodMatcher.requestSnapshotByteCount([original]), try pythonBudget(entries))
    var boundary = entries
    let base = try pythonBudget(boundary)
    boundary[0]["instructions", default: ""] += String(repeating: "a", count: 300_000 - base)
    XCTAssertEqual(try MathMethodMatcher.runtimeSnapshotByteCount(boundary), 300_000)
    XCTAssertEqual(try pythonBudget(boundary), 300_000)
    boundary[0]["instructions", default: ""] += "a"
    XCTAssertEqual(try MathMethodMatcher.runtimeSnapshotByteCount(boundary), 300_001)
    XCTAssertEqual(try pythonBudget(boundary), 300_001)
    XCTAssertThrowsError(try MathMethodMatcher.validateRequestBudget(Array(repeating: original, count: 513)))
  }
}
