import XCTest
@testable import VocabCapture

final class MathRendererContextTests: XCTestCase {
  func testOrdinaryEnglishAndCustomInstructionsRemainIntact() throws {
    let config = AIConfiguration(baseURL: "https://example.invalid/v1", model: "fixture", apiKey: "")
    let data = try ScreenshotQuestionClient.payload(question: "分析英语句法", context: .init(text: "He and I read.", selectedWord: nil, imageData: nil), history: [], configuration: config, api: .chatCompletions)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["instructions"] as? String, ScreenshotQuestionInstructions.text)
    let custom = "自定义：按用户要求使用中文，保留完整步骤。不要替我批准答案。"
    XCTAssertTrue(ScreenshotQuestionInstructions.forMathRendererTools(custom).contains(custom))
  }

  func testRendererPromptRetainsFullLocalMethodAndActualUserRequirements() {
    let fullText = "条件不足时拒绝本方法。" + String(repeating: "用户方法全文不可截断。", count: 300)
    let method = MathTeachingMethod(id: "local", versionID: "version", title: "用户方法", category: "自定义", instructions: fullText, createdAt: Date())
    let request = "请解答所有小问，详细说明并验算；不使用方程。"
    let prompt = MathStructuredSolution.prompt(request, candidates: [method], requireDiagram: true, singleSubmission: true, rendererTools: true)
    XCTAssertTrue(prompt.hasPrefix(MathStructuredSolution.rendererRequestPrefix))
    XCTAssertTrue(prompt.contains(request)); XCTAssertTrue(prompt.contains(fullText))
    XCTAssertTrue(prompt.contains("id:0\nroles:solution"))
    XCTAssertTrue(prompt.contains("null")); XCTAssertTrue(prompt.contains("visual_method_ids"))
    let system = ScreenshotQuestionInstructions.forMathRendererTools(ScreenshotQuestionInstructions.text)
    for guardrail in ["原题照片优先", "OCR仅辅助", "禁止编造来源和运算", "不代表答案已获人工核验", "完整解答所有请求题号", "submit_general_math_solution"] {
      XCTAssertTrue(system.contains(guardrail), guardrail)
    }
  }

  func testDefaultMathSystemOmitsEnglishGrammarWithoutChangingCustomOrReadingRules() {
    let math = ScreenshotQuestionInstructions.forMathRendererTools(ScreenshotQuestionInstructions.text)
    XCTAssertTrue(math.contains("数学学习助教"))
    for unrelated in ["中文阅读助教", "考试英语", "主语用主格", "修改格时", "词典 JSON"] {
      XCTAssertFalse(math.contains(unrelated), unrelated)
      XCTAssertTrue(ScreenshotQuestionInstructions.text.contains(unrelated))
    }
    XCTAssertTrue(math.contains("最新问题中用户明确提供的新条件或修正优先于旧来源"))
    let custom = "用户自定义：即使出现考试英语也保留本要求。"
    XCTAssertTrue(ScreenshotQuestionInstructions.forMathRendererTools(custom).hasPrefix(custom))
  }

  func testRendererContractRetainsAllUniqueSourceAndArithmeticBoundaries() {
    let compact = MathStructuredSolution.rendererDiagramContract
    for rule in ["图解语义约束", "evidence只保留原题这句", "差能被9整除", "小数、多零、中间漏零或含否定条件", "保留重复名称和顺序", "不能混用单位或补造资源", "未知量保持未知", "无环运算关系", "运算结果不能引用自身", "规则常数须说明数学规则", "不输出坐标或SVG"] {
      XCTAssertTrue(compact.contains(rule), rule)
    }
    XCTAssertLessThan(compact.count, MathStructuredSolution.submissionDiagramContract.count)
    XCTAssertTrue(MathStructuredSolution.submissionDiagramContract.contains("return_deadline："), "Legacy protocol stays intact")
    XCTAssertFalse(compact.contains("return_deadline："), "Renderer tool owns the duplicate description")
  }

  func testReviewedOriginalsRolloutDoesNotEnableUnvalidatedModelsOrEndpoints() {
    func allowed(_ model: String, _ url: String = "https://api.deepseek.com", _ api: ScreenshotQuestionAPI = .automatic) -> Bool {
      MathReviewedExample.supportsAutomaticUse(configuration: .init(baseURL: url, model: model, apiKey: ""), api: api)
    }
    XCTAssertTrue(allowed("deepseek-flash"))
    XCTAssertTrue(allowed("deepseek-flash", "https://api.deepseek.com/chat/completions", .chatCompletions))
    for model in ["gpt-6.1-sol", "claude-sonnet-5-5", "kimi-k2.6", "deepseek-unknown"] {
      XCTAssertFalse(allowed(model))
    }
    XCTAssertFalse(allowed("deepseek-flash", "https://example.invalid"))
    XCTAssertFalse(allowed("deepseek-flash", "http://api.deepseek.com"))
    XCTAssertFalse(allowed("deepseek-flash", "https://api.deepseek.com", .responses))
  }

  func testProfileChangeRejectsHistoricalImagesBeforeNetworkWithoutClaimingTheyWereProvided() async throws {
    let example = MathReviewedExample(reference: .init(questionID: "q", solutionID: "s", reviewID: "r", scope: "最终答案", title: "历史题"), text: "旧题", answer: "旧答案", imageData: Data())
    let client = ScreenshotQuestionClient(session: URLSession(configuration: .ephemeral))
    do {
      _ = try await client.answer(question: "解题", context: .init(text: "当前题", selectedWord: nil, imageData: nil, mathReferences: [example]), history: [], configuration: .init(baseURL: "https://example.invalid", model: "claude-sonnet-5-5", apiKey: ""), onPartial: { _ in
        XCTFail("An unvalidated reference request must never reach a provider")
      })
      XCTFail("Profile changed to an unvalidated configuration")
    } catch {
      guard case ScreenshotQuestionError.invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
    }
  }
}
