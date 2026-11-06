import XCTest

@testable import VocabCapture

final class MathSkillsTransportTests: XCTestCase {
  private let configuration = AIConfiguration(
    baseURL: "https://example.com/v1", model: "test-model", apiKey: "test-only")

  func testExistingMethodReviewCanUseItsEvidenceWithoutScreenshot() throws {
    let learning = try JSONSerialization.data(withJSONObject: ["profile_review": ["method_id": "method"]])
    let bytes = try ScreenshotQuestionClient.learningPayload(
      learning: learning, imageData: Data(), methods: [], configuration: configuration)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(payload["task"] as? String, "math_skill_learning")
    let context = try XCTUnwrap(payload["context"] as? [String: Any])
    XCTAssertFalse(try XCTUnwrap(context["text"] as? String).isEmpty)
    XCTAssertNil(context["image_data"])
    XCTAssertNotNil((payload["learning"] as? [String: Any])?["profile_review"])
  }

  func testSingleVersionProfileReviewDoesNotAttachUnrelatedInventory() throws {
    let body = "完整待审方法与反例。"
    let profile: [String: Any] = ["method_id": "reviewed", "version_id": "exact-version", "instructions": body,
      "binding_digest": "bound-evidence"]
    let learning = try JSONSerialization.data(withJSONObject: ["profile_review": profile])
    let inventory = (0..<8).map { index in
      MathTeachingMethod(id: "unrelated-\(index)", versionID: "old-\(index)", title: "其它方法",
        category: "自定义", instructions: String(repeating: "无关正文", count: 5000), createdAt: Date())
    }
    let bytes = try ScreenshotQuestionClient.learningPayload(learning: learning, imageData: Data(),
      methods: inventory, configuration: configuration)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertTrue(try XCTUnwrap(payload["teaching_skills"] as? [[String: String]]).isEmpty)
    let exact = try XCTUnwrap((payload["learning"] as? [String: Any])?["profile_review"] as? [String: Any])
    XCTAssertEqual(exact["version_id"] as? String, "exact-version")
    XCTAssertEqual(exact["instructions"] as? String, body)
    XCTAssertLessThan(bytes.count, 10_000)
  }

  func testBackgroundCoverageCarriesCompleteInventorySeparatelyFromModelWorkset() throws {
    let methods = (0..<4).map { index in
      MathTeachingMethod(id: "inventory-\(index)", versionID: "v1", title: "方法",
        category: "自定义", instructions: String(repeating: "完整正文", count: 10000), createdAt: Date())
    }
    let learning = try JSONSerialization.data(withJSONObject: ["evidence": [], "originals": []])
    let bytes = try ScreenshotQuestionClient.learningPayload(learning: learning, imageData: Data(),
      methods: methods, configuration: configuration)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertNil(payload["teaching_skills"])
    let catalogue = try XCTUnwrap(payload["teaching_catalogue"] as? [[String: String]])
    XCTAssertEqual(catalogue.map { $0["instructions"] }, methods.map { Optional($0.instructions) })
    XCTAssertGreaterThan(bytes.count, 300_000)
  }

  func testMethodContentsTravelAsVersionedSkillsOutsideUserQuestion() throws {
    let method = MathTeachingMethod(
      id: "sum-difference", versionID: "reviewed-version", title: "和差问题", category: "数量关系",
      instructions: "同一组数量的和与差。完整条件不截断。", createdAt: Date())
    let bytes = try ScreenshotQuestionClient.payload(
      question: "请不用方程", context: .init(text: "两人共有72本，相差18本。", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: .automatic, teachingSkills: [method])
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(payload["task"] as? String, "math_method_selection")
    XCTAssertEqual(payload["question"] as? String, "请不用方程")
    let skills = try XCTUnwrap(payload["teaching_skills"] as? [[String: String]])
    XCTAssertEqual(skills.count, 1)
    XCTAssertEqual(skills[0]["version_id"], method.versionID)
    XCTAssertEqual(skills[0]["instructions"], method.instructions)
    XCTAssertNil(payload["response_mode"])
  }

  func testEnglishRequestKeepsExistingPayloadWithoutMathSkills() throws {
    let bytes = try ScreenshotQuestionClient.payload(
      question: "Explain streaming", context: .init(text: "Streaming is crucial.", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: .automatic)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertNil(payload["task"])
    XCTAssertNil(payload["teaching_skills"])
    XCTAssertNil(payload["response_mode"])
    XCTAssertEqual(payload["question"] as? String, "Explain streaming")
    XCTAssertEqual(payload["instructions"] as? String, ScreenshotQuestionInstructions.text)
  }

  func testProjectDiscoveryMetadataFollowsExactVersionAndDoesNotDescribeLocalEdits() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first)
    func payload(_ instructions: String) throws -> [String: String] {
      let method = MathTeachingMethod(
        id: skill.sourceID, versionID: "local-version", title: skill.title,
        category: skill.category, instructions: instructions, createdAt: Date())
      let bytes = try ScreenshotQuestionClient.payload(
        question: "请解题", context: .init(text: "本题条件", selectedWord: nil, imageData: nil),
        history: [], configuration: configuration, api: .automatic, teachingSkills: [method])
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      return try XCTUnwrap((object["teaching_skills"] as? [[String: String]])?.first)
    }
    let original = try payload(skill.instructions)
    XCTAssertEqual(original["skill_name"], skill.name)
    XCTAssertEqual(original["description"], skill.description)
    XCTAssertEqual(original["instructions"], skill.instructions)
    let edited = try payload("用户更换适用条件与解题步骤")
    XCTAssertNil(edited["skill_name"])
    XCTAssertNil(edited["description"])
    XCTAssertEqual(edited["instructions"], "用户更换适用条件与解题步骤")
  }

  func testDiagramOutputUsesSeparateBudgetMode() throws {
    let bytes = try ScreenshotQuestionClient.payload(
      question: "请解题，输出 ```math-diagrams 数据块", context: .init(text: "72和18", selectedWord: nil, imageData: nil),
      history: [], configuration: configuration, api: .automatic)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(payload["response_mode"] as? String, "math_diagrams")
    XCTAssertNil(payload["teaching_skills"])
    let instructions = try XCTUnwrap(payload["instructions"] as? String)
    XCTAssertTrue(instructions.contains("必须输出"))
    XCTAssertTrue(instructions.contains("```math-diagrams"))
    XCTAssertFalse(instructions.contains("不用 Markdown 标题、加粗或代码围栏"))
  }
}
