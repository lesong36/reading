import Foundation
import NaturalLanguage
import XCTest
@testable import VocabCapture

final class MathLocalSkillRetrievalTests: XCTestCase {
  func testIncompleteMagicWholePageOCRDoesNotDisplaceRequestedMethod() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_INCOMPLETE_MAGIC_IMAGE"] else { throw XCTSkip("Set original incomplete-magic page") }
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "magic-and-latin-grid-constraints" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "magic-page", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let request = "只解第5题五阶幻方，不解同页其它题。四年级，不用方程，按原图逐格保留已知数，说明幻和怎样求出，再求星号并补全表格。逐行逐列及两条对角线验算；不假定所有数字互不相同或只用1至25。"
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: hint)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(hint); candidates: \(result.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt(request, candidates: result, singleSubmission: true, rendererTools: true).contains(skill.instructions))
  }
  func testIncompleteHigherOrderMagicRecallFromActualRequest() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "magic-and-latin-grid-constraints" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "higher-order-magic", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    for request in ["只解第5题五阶幻方，不解同页其它题。四年级，不用方程，按原图逐格保留已知数，说明幻和怎样求出，再求星号并补全表格。逐行逐列及两条对角线验算；不假定所有数字互不相同或只用1至25。",
                    "完成五阶幻方，幻和未知，允许重复数字和0，求星号。",
                    "补全5×5幻方，保留已知格，求未知幻和及符号。"] {
      let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: "")
      XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "\(request): \(result.map(\.title))")
      XCTAssertTrue(MathStructuredSolution.prompt(request, candidates: result, singleSubmission: true, rendererTools: true).contains(skill.instructions))
    }
  }
  func testOriginalLayeredPaperOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_LAYERED_PAPER_IMAGE"] else { throw XCTSkip("Set original layered-paper crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "layered-paper-occlusion-order" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "layered-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt("四年级解题。", candidates: result, singleSubmission: true, rendererTools: true).contains(skill.instructions))
  }
  func testOriginalDirectedPathOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_DIRECTED_PATH_IMAGE"] else { throw XCTSkip("Set original directed-path crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "directed-acyclic-path-counting" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "directed-path-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
  }
  func testOriginalSimplePathOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_SIMPLE_PATH_IMAGE"] else { throw XCTSkip("Set original simple path crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "simple-paths-with-visited-state" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "simple-path-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题，允许拓展知识。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
    let restricted = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题，不允许拓展知识。", textHint: text)
    XCTAssertFalse(restricted.contains { $0.id == skill.sourceID })
    let unspecified = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertFalse(unspecified.contains { $0.id == skill.sourceID })
  }
  func testOriginalCubePathOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_CUBE_PATH_IMAGE"] else { throw XCTSkip("Set original cube path crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "cube-surface-opposite-vertex-shortest" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "cube-path-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
  }
  func testOriginalBoundaryChordOCRAndPrompt() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_CHORD_IMAGE"] else { throw XCTSkip("Set original partition crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "boundary-chord-symbol-partition" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "chord-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt("四年级解题。", candidates: result, singleSubmission: true, rendererTools: true).contains(skill.instructions))
  }
  func testBoundaryChordPartitionRecallAndOrdinaryShapeBoundary() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "boundary-chord-symbol-partition" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "chords", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let source = "在正方形边上的40个点中选出6个点，连出3条线段，将正方形分成6个部分，使得每个部分都恰好有1个三角形、2个小正方形。"
    let positive = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: source)
    XCTAssertTrue(positive.contains { $0.id == skill.sourceID }, "\(positive.map(\.title))")
    let negative = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "正方形边长5厘米，求面积。")
    XCTAssertFalse(negative.contains { $0.id == skill.sourceID }, "\(negative.map(\.title))")
  }
  func testNotchedRectangleThreePieceRecallAndBoundary() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "notched-rectangle-three-piece-square" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "notched", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let source = "一个5×7的大长方形左上角割去了一个2×3的小长方形，请把这个图形分成3部分，再拼成一个正方形。"
    let positive = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: source)
    XCTAssertTrue(positive.contains { $0.id == skill.sourceID }, "\(positive.map(\.title))")
    let negative = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "一个长方形长7厘米宽5厘米，求面积。")
    XCTAssertFalse(negative.contains { $0.id == skill.sourceID }, "\(negative.map(\.title))")
  }
  func testOriginalNotchedRectangleOCRAndPrompt() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_NOTCHED_IMAGE"] else { throw XCTSkip("Set original crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "notched-rectangle-three-piece-square" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "notched-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
    XCTAssertTrue(MathStructuredSolution.prompt("四年级解题。", candidates: result, singleSubmission: true, rendererTools: true).contains(skill.instructions))
  }
  func testOriginalCrossImageOCRRecall() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_CROSS_IMAGE"] else { throw XCTSkip("Set original cross question crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "five-square-cross-dissection" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "cross-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
    let prompt = MathStructuredSolution.prompt("四年级解题。", candidates: result, singleSubmission: true, rendererTools: true)
    XCTAssertTrue(prompt.contains(skill.instructions), "The recalled method must reach the model as a complete candidate")
  }
  func testFiveSquareCrossDissectionCandidateRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "five-square-cross-dissection" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "cross", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "由5个小正方形组成的十字架，请将它剪成若干块，然后拼成一个大正方形。")
    XCTAssertTrue(result.contains { $0.id == expected.sourceID }, "\(result.map(\.title))")
  }
  func testOrdinarySquareAreaDoesNotMatchCrossDissection() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "five-square-cross-dissection" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "cross-negative", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "一个正方形的边长是5厘米，求它的面积。")
    XCTAssertFalse(result.contains { $0.id == skill.sourceID }, "\(result.map(\.title))")
  }
  func testOriginalSevenRectanglesCropOCRRecallsSkill() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_SEVEN_RECTANGLES_IMAGE"] else { throw XCTSkip("Set original crop path") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "seven-distinct-rectangles-grid" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "seven-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
  }
  func testOriginalTriangularGridOCRDoesNotImplyVisualRecognition() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_TRIANGULAR_GRID_IMAGE"] else { throw XCTSkip("Set original triangular-grid crop") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "triangular-grid-four-congruent-pieces" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "grid-ocr", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: text)
    XCTAssertFalse(text.contains("三角网"), "The source text does not describe its visual grid")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID }, "Recall a possible method for visual verification; OCR: \(text); candidates: \(result.map(\.title))")
    XCTAssertTrue(skill.instructions.contains("其他图"), "The model must still verify the figure before applying this construction")
  }
  func testTriangularGridFourPiecesCandidateRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "triangular-grid-four-congruent-pieces" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "triangular-four", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "三角网沿格线分割成大小形状都相同的4个部分，请画出具体分割方法。")
    XCTAssertTrue(result.contains { $0.id == expected.sourceID }, "\(result.map(\.title))")
  }
  func testSevenRectanglesCandidateRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "seven-distinct-rectangles-grid" })
    let methods = catalogue.skills.map { MathTeachingMethod(id: $0.sourceID, versionID: "seven-rectangles", title: $0.title, category: $0.category, instructions: $0.instructions, createdAt: Date()) }
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "沿格线分割成7个形状不同的长方形，包含正方形，请画分割线。")
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(candidates.map(\.title))")
  }
  func testMinimumSquareTilingRecallIsSpecific() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "five-square-minimum-square-tiling" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "five-square", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let match = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "用若干张边长为1、2、3、4的正方形纸片互不重叠地拼成一个边长为5的大正方形，最少需要多少张？")
    XCTAssertTrue(match.contains { $0.id == expected.sourceID }, "\(match.map(\.title))")
    let unrelated = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。", textHint: "正方形边长5厘米，面积多少？")
    XCTAssertFalse(unrelated.contains { $0.id == expected.sourceID })
  }
  func testFourPieceSquaresRecallAndDoNotCrowdOrdinaryArea() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "three-four-five-square-dissection" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "four-piece", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let match = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "将边长分别为3厘米和4厘米的两个正方形切割成4块，然后将它们拼成一个边长是5厘米的大正方形。请画出切割线和拼接线。")
    XCTAssertTrue(match.contains { $0.id == expected.sourceID }, "\(match.map(\.title))")
    let unrelated = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "正方形边长4厘米，求它的面积。")
    XCTAssertFalse(unrelated.contains { $0.id == expected.sourceID })
  }
  func testOriginalTriangleCropOCRRecallsSkill() async throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_TRIANGLE_ORIGINAL_IMAGE"] else { throw XCTSkip("Set original crop path") }
    let text = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: path)))
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "congruent-triangle-dissections" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "original-ocr", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。", textHint: text)
    XCTAssertTrue(result.contains { $0.id == expected.sourceID }, "OCR: \(text); candidates: \(result.map(\.title))")
  }
  func testCongruentTriangleDissectionRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "congruent-triangle-dissections" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "triangles", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let match = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "画三角形，分成5个大小相同形状相同的三角形，再画三角形分成13个全等三角形。")
    XCTAssertTrue(match.contains { $0.id == expected.sourceID }, "\(match.map(\.title))")
    let original = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "请画出一个三角形，并把它分成大小形状都完全相同的5个小三角形。如果要分为完全相同的13个小三角形，该如何画？")
    XCTAssertTrue(original.contains { $0.id == expected.sourceID }, "\(original.map(\.title))")
    let unrelated = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "直角三角形的底是6厘米、高是4厘米，求面积。")
    XCTAssertFalse(unrelated.contains { $0.id == expected.sourceID })
  }
  func testLayeredPaperRecallDoesNotReplaceGeneralGeometry() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "layered-paper-occlusion-order" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "layer-order", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let matching = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "8张大小相同的正方形纸片互相重叠，只露出一部分，求从上到下的摆放次序。")
    XCTAssertTrue(matching.contains { $0.id == expected.sourceID }, "\(matching.map(\.title))")
    let unrelated = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级解题。",
      textHint: "正方形边长8厘米，求它的面积。")
    XCTAssertFalse(unrelated.contains { $0.id == expected.sourceID })
  }
  func testEdgeTrailRecallRespectsExtensionPermission() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "edge-trails-parity-and-extrema" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "edge-trail-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint = "长方体木箱从A点出发沿棱爬行，每条棱只允许爬一次，最长多少厘米？如果回到A呢？"
    let allowed = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，允许拓展知识，不用方程。", textHint: hint)
    XCTAssertTrue(allowed.contains { $0.id == expected.sourceID }, "\(allowed.map(\.title))")
    let denied = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不允许拓展知识。", textHint: hint)
    XCTAssertFalse(denied.contains { $0.id == expected.sourceID })
  }
  func testSquareStripWindmillCandidateCanBeRecalled() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "square-strip-windmill-packing" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "windmill-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let hint = "从边长7厘米的正方形纸片中，最多裁出多少张长4厘米、宽1厘米的长方形纸条？请画图说明裁剪方法。"
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。", textHint: hint)
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(candidates.map(\.title))")
  }
  func testChaseBeforeShelterRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "shelter-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "motion-events-and-periodic-arrivals" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "猎狗追兔子速度是兔子的2倍，兔子径直往洞里跑，狗距洞1000米；当狗到兔子原位置时兔距洞100米。兔子原来距洞多少米，最终会被追上吗？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
    let ratio = try XCTUnwrap(catalogue.skills.first { $0.name == "sum-and-ratio" })
    XCTAssertTrue(result.contains { $0.id == ratio.sourceID })
  }
  func testApproachAndSeparationDistanceRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "separation-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "motion-events-and-periodic-arrivals" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "两地相距400千米，甲乙相向同时出发每小时60和40千米，第一次和第二次相距100千米各要多久？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testEqualStationsStaggeredThreeTravelersRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "stations-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "shared-clock-relative-motion" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "16个等距车站，甲到第2站时乙出发，乙到第3站时丙出发；丙在第4站追上乙，甲丙同时到第16站，求速度比。")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testMidpointDelayedDepartureRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "midpoint-delay-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "same-distance-delay-speed-change" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "甲乙从两地同时出发6小时相遇在中点；如果甲迟1小时出发，乙每小时少走4千米，仍在中点相遇，求两地距离。")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testCircularSeatingRotationRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "circular-seats-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "circular-seating-rotation-equivalence" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "7个人围着圆桌坐成一圈，有多少种不同的坐法？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testSharedTripSegmentCancellationRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "same-trip-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "motion-events-and-periodic-arrivals" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "平时先步行10分钟再跑2分钟，某天步行6分钟后跑步，比平时早到2分钟，跑速是步速几倍？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testIntegerAverageMergeExtremaRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "average-merge-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "integer-average-merge-extrema" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "黑板写1至10，每次擦掉两个奇偶性相同的数并写上平均数，最后一个数最大是多少？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testCubeSurfaceOppositeVertexShortestRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "cube-path-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "cube-surface-opposite-vertex-shortest" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "蚂蚁沿正方体表面从顶点A走到空间对顶点B，如何走最短，共有几条路线？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testCubeNetVertexSumRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "cube-net-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "cube-net-opposites-vertex-sums" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "正方体展开图折成正方体后，相交于同一个顶点的三个面上的数之和最大是多少？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testDistinctAdjacentDigitWindowRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "adjacent-window-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "distinct-adjacent-digit-windows" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "一个自然数由数字8、9组成，任意相邻两位组成的两位数都不相同，最大是多少？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testUnknownDistanceReboundMethodRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "rebound-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "rebound-meeting-unknown-distance" })
    for hint in ["两车从甲同时出发不断往返，第一次迎面距甲40千米，第二次迎面距乙10千米，求甲乙距离。",
                 "两车从甲乙两端同时出发不断往返，第一次迎面距甲40千米，第二次迎面距甲10千米，求甲乙距离。"] {
      let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。", textHint: hint)
      XCTAssertTrue(result.contains { $0.id == skill.sourceID }, hint)
    }
  }
  func testDigitSumRemainderExtremumIsRetrieved() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "digit-sum-remainder-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "digit-sum-division-remainders" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "一个两位数除以它的各位数字之和，余数最大是多少？")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testDigitProductBranchSkillIsRetrievedForThreeDigitFactors() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "digit-product-branch-test", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "digit-product-branch-enumeration" })
    let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "请用小学方法解题。",
      textHint: "2、3、4、5、6、8各用一次组成两个三位数，求乘积最大值。")
    XCTAssertTrue(result.contains { $0.id == skill.sourceID })
  }
  func testCenterBisectionRequiresAreaCutContext() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "central-symmetry-area-bisection" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "center-cut-test", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    for hint in ["长方形长宽和30、差6，求面积。", "正方形中有一个孔，但题图形状不明，求周长。"] {
      XCTAssertFalse(MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "请解题。", textHint: hint).contains { $0.id == method.id }, hint)
    }
    let hint = "外正方形与内部方孔中心相同，一条过中心直线能平分剩余面积吗？"
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "请解题。", textHint: hint).contains { $0.id == method.id })
  }

  func testCongruentRectangleSpansRequireTilingContext() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "congruent-rectangle-span-ratios" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "span-test", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    for hint in ["8×8正方形网格，每格边1厘米，求复杂阴影面积。", "长方形长宽和30，差6，求面积。", "8个面积相同的小长方形拼成大长方形，周长84，求面积。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "请用小学方法解题。", textHint: hint)
      XCTAssertFalse(candidates.contains { $0.id == method.id }, hint)
    }
    let hint = "7个全等小长方形拼成大长方形，上带4个竖放，下带3个横放，共宽，大周长76厘米。"
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "请用小学方法解题。", textHint: hint).contains { $0.id == method.id })
  }

  func testTriangularLatticeSourceRecallUsesExactOriginalMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "chapter417-triangle", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (name, hint) in [
      ("constrained-digit-extrema-and-exchange", "四位数包含3个相同数码，求与1389大减小之差最小的四位数。"),
      ("constrained-digit-extrema-and-exchange", "1至6各用一次组成两个三位数，前数大于后数，分别求最大和最小差。"),
      ("constrained-digit-extrema-and-exchange", "多位数各位数字互不相同，数字和为23，求最小和最大多位数。"),
      ("constrained-digit-extrema-and-exchange", "1、2、3、4、6、7、8、9各用一次组成两个四位数，求大减小的最小差。"),
      ("quota-preserving-digit-subsequence", "把1至30依次连接为一个多位数，删除45个数字；求剩余最大数，再求首位不为0时最小数。"),
      ("motion-events-and-periodic-arrivals", "两步行者相向行走，速度每小时6.5和6千米，距离75千米；骑车人每小时15千米在两人之间反复折返直到两人相遇，求骑行总路程。"),
      ("motion-events-and-periodic-arrivals", "甲乙丙同时出发，甲从A往B步行、乙从B往A步行、丙从B往A骑车，骑速是步速3倍。甲丙相遇时丙给甲车，甲乙相遇时甲给乙车，各人仍按原方向，问谁先谁后到目的地。"),
      ("motion-events-and-periodic-arrivals", "A、B相距56千米，甲乙从A向B每小时6和5千米、丙从B向A每小时4千米同时出发，问几小时后乙在甲丙中点。"),
      ("shared-route-and-event-alignment", "A、B相距120千米，甲乙相向1小时30分相遇，甲速50；相遇6分钟后甲遇丙，丙在C追乙。另一方案甲速44、乙快6，两人在C相遇，求丙速。"),
      ("shared-route-and-event-alignment", "三车同地同刻出发走同一全程，到终点用100、120、150分；迎面行人每分100米，快车30分、中车35分遇人，慢车多久遇人？"),
      ("multi-round-bijection-constraints", "五人同步交换五本不同书，每人读完五本，最后一本依次A至E；按六条跨轮线索求各人第四本。"),
      ("digit-block-count-and-position", "页码从1起连续编号，共用1983个数码，末页是多少？"),
      ("digit-block-count-and-position", "把1至2008依次写出，求总位数及第2008位数字。"),
      ("digit-block-count-and-position", "不超过1000的自然数中，数字9共出现多少次？"),
      ("timetable-capacity-and-conflicts", "四位教师各教两门课，两班同一时间不能由同一教师授课；结合课表与甲周二无课、乙周一不给一班上课、丙周二前两节有课、物理老师周一前两节无课，求每位教师教什么课。"),
      ("bounded-amount-reachable-sets", "1元3张、5元1张、10元2张，至少取1张，可组成多少不同总金额？"),
      ("circle-unique-adjacent-pair", "10人固定围成一圈，从中选3人，恰有2人相邻，有多少种选法？"),
      ("distinct-digit-position-sum", "用1至4组成没有重复数字的三位数，共多少个，这些数的和是多少？"),
      ("fixed-sum-product-extrema", "3个自然数的和是19，它们的乘积最大可能是多少？"),
      ("fixed-sum-product-extrema", "3个互不相同的自然数之和是17，它们的乘积最大可能是多少？"),
      ("shared-clock-relative-motion", "甲乙从A、B同时相向，甲速为乙2倍；到途中的C站分别为5:00和17:00，求相遇时刻。"),
      ("shared-clock-relative-motion", "甲乙从A、B相向1小时相遇；改同向且乙早发2小时，甲3小时追上乙，求速度比。"),
      ("shared-clock-relative-motion", "16个等距车站原图，甲到第2站乙出发，乙到第3站丙出发，丙第4站追上乙，甲丙同时到第16站，求甲乙速度比。"),
      ("shared-clock-relative-motion", "两人相距24千米同向，甲速加1乙速减1后追及提前2小时，追点相距12千米，求原速相向相遇时间。"),
      ("truth-count-and-weekday-cycle", "藏书数非负整数，四人说恰500本、至少1000本、不到2000本、至少1本，恰一句真话，求数量。"),
      ("truth-count-and-weekday-cycle", "狮子周一二三说谎，独角兽周四五六说谎，同一天都说昨天是我说谎日，今天星期几？"),
      ("integer-average-shift-recurrence", "三个不同整数之和2008，每次擦掉第一个数，在最后写上另外两个数的平均数，做7次后和159，所有写过的数都是整数，求开始的第一个数。"),
      ("motion-events-and-periodic-arrivals", "两列火车同方向齐头行进，快车每秒18米慢车10米，12秒快车超过；若车尾对齐则9秒快车超过，求两车车长。"),
      ("motion-events-and-periodic-arrivals", "货车和客车同向行驶，人沿车内前进方向每秒1米，客车速20米每秒，货车140秒超过人，客车长350米货车长280米，求货车完全超过客车时间。"),
      ("motion-events-and-periodic-arrivals", "货车和客车相向而行，车头在A相遇，车尾在B错开，AB距150米；客车长450米速108千米每时，货车速72千米每时且更长，求货车长。"),
      ("motion-events-and-periodic-arrivals", "一个人沿铁路向前走，货车8:00追上他30秒后超过；客车9:30迎面遇到他12秒后离开。客车长是货车2倍、速度3倍，求两车相遇时刻及错开时间。"),
      ("motion-events-and-periodic-arrivals", "火车长110米速30千米每时，14:10追上向北工人15秒后离开，14:16迎面遇到向南学生12秒后离开。求工人与学生相遇时刻。"),
      ("motion-events-and-periodic-arrivals", "行人骑车人同时从A城出发，速7.2和18千米每时，火车9:10追上行人20秒通过，9:18追上骑车人26秒通过，求车长、出发时刻和初始距离。"),
      ("motion-events-and-periodic-arrivals", "甲乙丙三列火车车长成等差、乙居中，甲丙车尾齐于A，乙车尾在B反向；10秒三车头相遇，再15秒甲完全超过丙且丙与乙错开，求甲乙相遇到错开的时间。"),
      ("train-length-and-event-reconciliation", "一个人沿铁路向前走，货车8:00追上他30秒后超过；客车9:30迎面遇到他12秒后离开。客车长是货车2倍、速度3倍，求两车相遇时刻及错开时间。"),
      ("train-length-and-event-reconciliation", "火车长110米速30千米每时，14:10追上向北工人15秒后离开，14:16迎面遇到向南学生12秒后离开。求工人与学生相遇时刻。"),
      ("train-length-and-event-reconciliation", "行人骑车人同时从A城出发，速7.2和18千米每时，火车9:10追上行人20秒通过，9:18追上骑车人26秒通过，求车长、出发时刻和初始距离。"),
      ("train-length-and-event-reconciliation", "甲乙丙三列火车车长成等差、乙居中，甲丙车尾齐于A，乙车尾在B反向；10秒三车头相遇，再15秒甲完全超过丙且丙与乙错开，求甲乙相遇到错开的时间。"),
      ("absolute-difference-median", "在图23-1中间圆内填一个数。该圆与外圈10、3、7各有一条线段相连。计算每条线段两端数的差（大减小），把3个差相加，所得和最小是多少？"),
      ("absolute-difference-median", "在图23-2中间圆内填一个数。该圆分别与15、7、10、1、5相连。计算每条线段两端数的差（大减小），把5个差相加，所得和最小是多少？"),
      ("shared-vertices-and-discrete-gaps", "一个六边形广场的边界上插有336面红旗和黄旗，六边形每个顶点处都插有红旗，每条边上红旗数目一样多，并且每两面红旗间插有相同数目的黄旗。已知每条边上黄旗比红旗的2倍还多12面，那么每两面红旗间插有几面黄旗？"),
      ("grouped-score-balance", "在一次速算比赛中，每题的分数是一样的，前20题中，小明做对了15题，余下的题中，他做对的题仅是做错的一半，最后一共得了50分。如果满分是100分，那么小明做对了多少题？"),
      ("common-component-and-aggregate-comparison", "小真、小想、小看原有的钱数成比例。小真加15元可以买3张电影票，小想减15元可以买3个一样的汉堡，小看加35元可以买2张电影票和2个汉堡，求原有的钱及票价。"),
      ("common-component-and-aggregate-comparison", "两款桌椅都包含1张桌子和若干把椅子，桌子的价钱一样，每把椅子的价钱也一样。第一款6把椅子总价700元，第二款9把椅子总价970元。1张桌子价钱多少元？"),
      ("first-period-lead-and-catchup", "小白兔与小黑兔采摘胡萝卜后平分，小白兔当天吃4个，往后每天4个；小黑兔当天吃12个，往后每天2个，最后同时把各自的胡萝卜吃完。一共采摘多少个？"),
      ("proportional-stock-consumption-baselines", "甲零件原为乙零件2倍，每件产品需要5个甲和2个乙。加工30件后，剩下甲乙数量相等，还可以加工成几件产品？"),
      ("common-component-and-aggregate-comparison", "甲乙丙丁四班，不算甲其余总131人，不算丁其余总134人；乙丙两班总人数比甲丁总人数少1人。四班共有多少人？"),
      ("common-component-and-aggregate-comparison", "按合同干满30天，工厂给一套工作服和70元。实际工作20天中止合同，只给同样一套工作服和20元。这套工作服值多少元？"),
      ("first-period-lead-and-catchup", "两人看同一本小说，卡莉娅打算第一天看50页，接着每天看15页；墨莫打算每天看22页，最后正好同一天看完。小说共多少页？"),
      ("proportional-stock-consumption-baselines", "福特汽车数量是丰田3倍，每周销售2辆丰田和4辆福特，当丰田销售完时还剩30辆福特。原有丰田和福特各多少辆？"),
      ("proportional-stock-consumption-baselines", "食堂大米袋数是面粉4倍，每天耗面粉20袋、大米60袋，几天后面粉全用完，大米还剩200袋。买来大米多少袋？"),
      ("proportional-stock-consumption-baselines", "水果糖原比巧克力糖3倍多10颗，每袋装3颗巧克力和7颗水果糖。巧克力全装完，水果糖剩170。原水果糖、巧克力各多少颗？"),
      ("common-component-and-aggregate-comparison", "电视首月付款750元，以后每月150元；或前一半时间每月300元、后一半每月100元。两方案付款总数和时间相同，电视价格多少元？"),
      ("common-component-and-aggregate-comparison", "三人行李均超过免费重量，分别付20、40、60元，合重150千克。若一人带全部行李，需付超重费240元。每人可免费带多少千克？"),
      ("proportional-stock-consumption-baselines", "橘子原为梨3倍，全家每天吃5橘子、2梨，一星期后橘子是梨4倍少5个。原橘子和梨分别多少个？"),
      ("weighted-class-capacity-and-attainment", "把31个桃子分给若干只猴子，每只猴子分得的桃子不超过3个。那么至少有几只猴子分得的桃子一样多？"),
      ("adaptive-bijection-trials-and-adversary", "现有10把钥匙分别能开10把锁，但是不知道哪把钥匙能开哪把锁。那么最少要试验多少次才能保证使全部的钥匙和锁相匹配？"),
      ("circular-cover-gap-and-window-capacities", "圆桌周围恰好有12把椅子，现在已经有一些人在桌边就座。当再有一人入座时，就必须和已就座的某个人相邻。问：已就座的最少有多少人？"),
      ("circular-cover-gap-and-window-capacities", "31个同学围成一个圆圈，坐好后发现任何2个男生之间至少有2个女生。那么最多有多少个男生？"),
      ("circular-cover-gap-and-window-capacities", "有37个数，每个数为0或1。要求当这些数以任意的方式排列在圆周上时，总能找到6个1连在一起。问其中最少有多少个数是1？"),
      ("circular-cover-gap-and-window-capacities", "888名学生站成一个圆圈，如果任意连续32人中，至多有9名男生，那么男生最多有多少人？"),
      ("bounded-inventory-threshold-guarantees", "黑色、白色、黄色、红色的筷子各有8根，混放在一起，在黑暗中取出一些筷子，要使得这些筷子能够搭配出两双筷子（两根筷子颜色相同时为一双），那么最少要取多少根才能保证达到要求？"),
      ("bounded-inventory-threshold-guarantees", "将1只白袜子、2只黑袜子、3只红袜子、8只黄袜子和9只绿袜子放入一个布袋里。一次至少要摸出多少只才能保证颜色相同的两双？多少只才能保证颜色不同的两双？两只同色为一双。"),
      ("bounded-inventory-threshold-guarantees", "大口袋装球，写0的1个，写1的2个，写2的3个……写9的10个。闭眼至少取多少个球，才能保证三个球的数字恰好组成678？考虑9倒过来看是6。"),
      ("bounded-inventory-threshold-guarantees", "袋中红球7个、黄球5个、绿球8个，闭眼取球，保证有一种颜色不少于4个至少取多少？如果还要保证另一种颜色不少于3个，至少取多少？"),
      ("bounded-inventory-threshold-guarantees", "抽奖箱有5色奖券，分别32、30、28、26、24张，每抽一张2元。15张同色换飞机模型，11张同色换坦克模型，4张同色换摩托车模型。至少付多少元保证换到三种模型，且三种模型颜色互不相同？"),
      ("central-symmetry-area-bisection", "如图4-2，在一块正方形纸片中有一个正方形的空洞。现在要求用一条经过大正方形中心的线段，把纸片分成面积相等的两部分，应该怎么分？"),
      ("congruent-rectangle-span-ratios", "如图7-13，8个同样大小的小长方形拼成了一个大长方形。已知大长方形的周长是84厘米，那么大长方形的面积是多少平方厘米？"),
      ("base-height-area-relations", "如图7-28，梯形ABCD面积为45，BC=10，高为6。已知三角形ADE的面积为5，则三角形BEC的面积是多少？"),
      ("base-height-area-relations", "如图7-29，直角梯形ABCD中，AB=15厘米，BC=12厘米，AF垂直于AB，阴影部分的面积为15平方厘米。问梯形ABCD的面积是多少平方厘米？"),
      ("square-corner-cuts-and-area-differences", "如图7-20，把小正方形的每边延长2厘米后，得到一个大正方形，大正方形的面积比小正方形的面积大36平方厘米。那么小正方形的边长是多少厘米？"),
      ("square-corner-cuts-and-area-differences", "图7-25中有3个大小不同的正方形，其中大正方形的周长比小正方形的周长长8，大正方形的面积比中正方形的面积大12。问大正方形的面积是多少？"),
      ("square-corner-cuts-and-area-differences", "如图7-26，中、小两个正方形把大正方形分成了3个部分，外层环形部分的面积为168，中层环形部分的面积为96。如果3个正方形的边长构成等差数列，那么大正方形的面积是多少？"),
      ("square-corner-cuts-and-area-differences", "图7-27是一块正方形地砖示意图，其中AA1=AA2=BB1=BB2=CC1=CC2=DD1=DD2，红色小正方形的面积是4，4块绿色小三角形的面积总和是18，求大正方形ABCD的面积。"),
      ("base-height-area-relations", "如图7-18，ABFE和CDEF都是长方形，AB的长是4厘米，BC的长是3厘米。那么图中阴影部分的面积是多少平方厘米？"),
      ("base-height-area-relations", "如图7-19，平行四边形ABCD的面积是32平方厘米，三角形CED是一个直角三角形。已知AE=5厘米，CE=4厘米，那么阴影部分的面积是多少平方厘米？"),
      ("base-height-area-relations", "如图7-21，小正方形ABCD放在大正方形EFGH的上面。已知小正方形的边长为4厘米，且梯形AEHD的面积是28平方厘米，那么梯形AFGD的面积是多少平方厘米？"),
      ("base-height-area-relations", "如图7-22，在直角梯形ABCD中，三角形ABE和三角形CDE都是等腰直角三角形，且BC=20厘米。那么直角梯形ABCD的面积是多少？"),
      ("base-height-area-relations", "如图7-23，平行四边形的一边长为15厘米，这条边上的高为6厘米，一条线段将此平行四边形分成了两部分，它们的面积相差18平方厘米。请问：其中梯形的上底是多少厘米？"),
      ("base-height-area-relations", "如图7-24，梯形ABCD的上底AD长5厘米，下底BC长12厘米，腰CD的长为8厘米，过B点向CD作出的垂线BE的长为9厘米。那么梯形ABCD的面积是多少？"),
      ("base-height-area-relations", "小中大三个正方形同底依次紧挨，边长3、7、9，求原图两个阴影平行四边形各自面积。"),
      ("base-height-area-relations", "边长8厘米大正方形左上角放边长6厘米小正方形，连接两方形右下角，求下方阴影梯形面积。"),
      ("base-height-area-relations", "四个边长6的小正方形拼大正方形，取每个小方形上下边中点按原图连成四个阴影平行四边形，求总面积。"),
      ("base-height-area-relations", "梯形内两平行四边形ABEF和CDFG，AF10米、FD4米、ABEF面积60平方米，求CDFG面积。"),
      ("base-height-area-relations", "边8和6厘米两正方形同底相邻，原图1阴影为接缝高差段与小方形右下点的三角形，图2阴影为左下点与小方形上边的三角形，分别求面积。"),
      ("base-height-area-relations", "正方形ABCD的对角线AC长8厘米，面积多少平方厘米？"),
      ("base-height-area-relations", "平行四边形AD20厘米、高CH9厘米，E在BC上BE6厘米，F在AD上，求阴影ABE与FEC面积之和。"),
      ("base-height-area-relations", "平行四边形BCE面积42平方厘米、BC14厘米、E在AD上AE9厘米，求全平行四边形面积和ECD面积。"),
      ("base-height-area-relations", "两个边10厘米正方形竖向错开3厘米，原图阴影平行四边形斜边沿左方形对角线延伸，求阴影面积。"),
      ("base-height-area-relations", "两直角三角形共斜边拼四边形，原图阴影一三角底2对应直角高6，另一三角底5对应高4，求阴影总面积。"),
      ("base-height-area-relations", "矩形18×10厘米，CP4厘米，E/F/G分别是AB/AD/CD中点，求原图阴影AEP、FDP、PCG总面积。"),
      ("base-height-area-relations", "正方形被两平行线分成等面积三份，上下两份为等腰直角三角形，两截线都长6厘米，求正方形面积。"),
      ("fixed-count-grid-piece-reassembly", "上两行各6格、底下一行仅第3至6列的16格阶梯图，沿格线剪成两块再拼成正方形，给切线与每块去向。"),
      ("fixed-count-grid-piece-reassembly", "L形上宽3、左高7、右上竖边3、台阶宽1、右下竖边4，剪成3块再拼成正方形，画切线和拼缝。"),
      ("fixed-count-grid-piece-reassembly", "6×2正方格长方形沿格线剪成两块再拼成3×4长方形，请保留整块给出移动。"),
      ("grid-partition-and-tiling", "6×6方格各行原字母为..C.D.、DB.CD.、.AAA..、....BB、B..A..、CC...D，点为无字母，沿格线分四全等连通块，每块各有A、B、C、D。"),
      ("grid-partition-and-tiling", "4×4方格各行原字母为.A.A、ABB.、...B、.B.A，点为无字母，分四全等连通块，每块各有A、B。"),
      ("grid-partition-and-tiling", "5列3行方格矩形上方中央再加1格，沿格线分为四个大小形状相同的连通部分，允许旋转翻转，请画分界。"),
      ("grid-partition-and-tiling", "L形总宽12总高8，左下高4顶宽4，分成四个大小形状完全相同的块，至少画四种不同分法。"),
      ("grid-partition-and-tiling", "方格图各行从上至下为2、4、6、8、6、4、2格且居中，沿格线分成四个全等连通部分，可以旋转翻转，能给几种不同分法？"),
      ("nested-square-size-inventory", "把一个大正方形分成6个或7个小正方形，要求恰两种不同面积，画出分割方案。"),
      ("nested-square-size-inventory", "大正方形分割为12个小正方形，分别形成2、3、4种面积不同的小正方形。"),
      ("extremal-bounds-and-construction", "7个长4厘米宽3厘米的完整长方形无重叠无空隙拼成长方形，周长最小多少，画具体拼法。"),
      ("grid-partition-and-tiling", "7个长4厘米宽3厘米的完整长方形无重叠无空隙拼成长方形，周长最小多少，画具体拼法。"),
      ("rectangle-staircase-reassembly", "长方形长25厘米宽16厘米，剪成两块，再拼成一个正方形，怎样剪拼？"),
      ("rectangle-staircase-reassembly", "25×49长方形纸片，沿横7竖5的小矩形虚线剪成3块，再拼成边长35厘米正方形，标明切线和拼缝。"),
      ("equal-square-diagonal-reassembly", "有两个面积相等的正方形纸片，分别剪开两张，拼成一个更大的正方形，应该怎样分块？"),
      ("equal-square-diagonal-reassembly", "两张同大的正方形，只允许剪开一个正方形，另一张完整，拼成一个更大的正方形，怎样剪拼？"),
      ("square-cyclic-midpoint-dissection", "正方形边长2厘米，分别连接四个顶点与对应非相邻边中点，按同一循环接法围成中央阴影，求面积。"),
      ("triangular-lattice-area-dissection", "大正六边形面积72平方米，三图依次为相间边中点三角交集、六边中点六边形、相间原顶点三角交集，分别求阴影面积。"),
      ("regular-dodecagon-unit-dissection", "正12边形边长1厘米，每条外边上朝内画同边长正三角形，共12个阴影三角，求剩余空白面积。"),
      ("triangular-lattice-area-dissection", "图17-26每个小等边三角形面积1平方米，求七顶点阴影面积。"),
      ("lattice-polygon-area", "8×8正方形网格，每格边1厘米，图17-27复杂阴影由外轮廓与内轮廓之间组成，求面积。"),
      ("base-height-area-relations", "四边形左下和上角是直角，右下45°，底边7厘米，左上斜边3厘米，求面积。"),
      ("integer-lattice-triangle-extrema", "4行4列共16个钉子，相邻间隔1厘米；套三角形，面积相同但形状不同只算一种。能有多少种不同面积？"),
      ("integer-lattice-triangle-extrema", "80×100长方形网格ABCD，每个小方格面积1；选格点P使固定对角线AC所构三角形PAC面积最小且不能为0。"),
      ("rectilinear-area-and-perimeter", "图示六条水平竖直边的L形凹六边形，边长分别1、2、3、4、5、7，求最大可能面积。"),
      ("extremal-bounds-and-construction", "图示六条水平竖直边的L形凹六边形，边长分别1、2、3、4、5、7，求最大可能面积。"),
      ("lattice-polygon-area", "图17-11相邻格点围成的最小正方形或正三角形面积均为1平方米，求三幅多边形a、b、c面积。"),
      ("lattice-polygon-area", "图17-12每个最小正方形面积2平方厘米，图17-13每个最小正三角形面积4平方厘米，分别求帆船和三角网风帆的阴影面积。"),
      ("triangular-lattice-area-dissection", "图17-11相邻格点围成的最小正方形或正三角形面积均为1平方米，求三幅多边形a、b、c面积。"),
      ("triangular-lattice-area-dissection", "图17-12每个最小正方形面积2平方厘米，图17-13每个最小正三角形面积4平方厘米，分别求帆船和三角网风帆的阴影面积。"),
      ("base-height-area-relations", "小正方形与大正方形同底相邻，边长4和6，阴影三角连接小方形左上角和大方形左上、右下角，求面积。"),
      ("base-height-area-relations", "ABCD长方形AD长7、AB长5，CDEF平行四边形，BH长3，求图中阴影面积。"),
      ("right-isosceles-inscribed-figures", "ABC和DFE是两个完全相同等腰直角三角形，E、B、F、C在同一直线依次排列，AB与DF在同侧垂直底线，DF长9，CF长3，求重叠阴影面积。"),
      ("base-height-area-relations", "边长1米的正方形与等腰梯形拼成火炬，上底1.5米，A、B分别上下底中点，高AB长0.5米，CD长0.3米，求阴影面积。"),
      ("right-isosceles-inscribed-figures", "正方形ABCD边长6，内部长方形EFGH四点分别在四边，AE=AH=2，求长方形面积。"),
      ("right-isosceles-inscribed-figures", "两个相同等腰直角三角形，各内接正方形A和B，A两边沿直角边、B一边沿斜边，A面积36，求B面积。"),
      ("triangular-lattice-area-dissection", "两个相同正三角形分别五等分和七等分；图17-15阴影294平方分米，图17-16阴影求面积。"),
      ("triangular-lattice-area-dissection", "正六边形ABCDEF面积6平方厘米，M、N、P分别为AB、CD、EF中点，求三角形MNP面积。"),
      ("triangular-lattice-area-dissection", "均匀三角形点阵，最小等边三角形面积1平方厘米，图17-4三个多边形求面积。"),
      ("triangular-lattice-area-dissection", "三角网每个最小等边三角形面积1，图17-5求四边形ABCD和三角形EFG面积。"),
      ("base-height-area-relations", "大等腰直角三角形ABC剪小等腰直角三角形AED，BC=10、DE=4，求剩余阴影面积。"),
      ("triangular-lattice-area-dissection", "均匀三角网最小等边三角形面积4平方厘米，一三角底沿格线跨3步，顶点到该底线跨4排平行行距，求面积。")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testSquareSizeInventoryNeedsAPartitionIntoSmallSquares() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "nested-square-size-inventory" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "square-size-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("大正方形分成7个小正方形，恰两种面积。", true),
      ("将大正方形分割成12个小正方形，三种大小。", true),
      ("正方形边长7厘米，求面积。", false),
      ("三角形分成5个全等小三角形。", false),
      ("长方形分割成7个形状不同的小长方形。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == method.id }, expected, hint)
    }
  }

  func testStaircaseCutsRequireRectangleAndReassembly() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "rectangle-staircase-reassembly" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "staircase-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("长方形25×16厘米，剪两块拼成正方形。", true),
      ("49×25矩形，切三块拼成35厘米正方形。", true),
      ("长方形分成两块拼成正方形。", true),
      ("长方形25×16厘米，求面积。", false),
      ("两张正方形纸片剪拼。", false),
      ("直角三角形剪拼正方形。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == method.id }, expected, hint)
    }
  }

  func testEqualSquareReassemblyDoesNotDisplaceGenericAreaMethods() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "equal-square-diagonal-reassembly" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "two-square-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("两张同大正方形纸片，剪拼成大正方形。", true),
      ("有两个面积相等的正方形，只剪其中一个，怎样拼？", true),
      ("8×8正方形网格，求复杂阴影面积。", false),
      ("正方形对角线求三角面积。", false),
      ("两张长方形剪拼。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == method.id }, expected, hint)
    }
  }

  func testCyclicMidpointMethodRequiresItsConnectionPattern() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "square-cyclic-midpoint-dissection" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "cyclic-midpoint-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("正方形四个顶点分别连接对应边中点，求中央面积。", true),
      ("正方形顶点连对边中点围成阴影。", true),
      ("正方形连接各边中点得到小正方形。", false),
      ("正方形顶点连相邻边中点。", false),
      ("正六边形顶点连对边中点。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testDodecagonMethodNeedsNamedPolygonEvidence() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "regular-dodecagon-unit-dissection" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "dodecagon-type-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("正十二边形每边朝内画等边三角形，求空白面积。", true),
      ("正12边形的阴影外面积。", true),
      ("最小正三角形面积1，求三角网阴影面积。", false),
      ("正方形网格8×8，求阴影。", false),
      ("正六边形面积72，求三图阴影。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testAreaExtremumRecallRequiresAnOptimisationRequest() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "extremal-bounds-and-construction" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "area-extremum-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("这个图形的最大面积是多少？", true),
      ("格点三角形最小非零面积。", true),
      ("三角形面积是多少？", false),
      ("每个最小正方形面积2，最小正三角形面积4，求阴影面积。", false),
      ("停车场原有多少辆车？", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testSquareCornerRecallRequiresSpecificConstructionEvidence() throws {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == "square-corner-cuts-and-area-differences" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "square-corners", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("小正方形每边延长2厘米，外方形面积多36，求内边长。", true),
      ("三个正方形边长等差，两层环面积已知，求最大面积。", true),
      ("正方形面积多少，边长8厘米。", false),
      ("正方形网格上数三角形面积种类。", false),
      ("长方形长宽和差已知，求面积。", false),
      ("买红绿正方形饼干，求总价。", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testAreaRecallKeepsUnrelatedStoriesOut() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "base-height-area-relations" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "area-recall",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("阴影三角形求面积。", true),
      ("梯形求面积。", true),
      ("平行四边形求面积。", true),
      ("四边形求面积。", true),
      ("多边形阴影面积。", true),
      ("两个长方形中的阴影面积是多少？", true),
      ("矩形内部图形求面积。", true),
      ("正方形对角线已知，求面积。", true),
      ("买长方形饼干，求总价。", false),
      ("买三角饼干，求总价。", false),
      ("面积图如何解释停车数量？", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testSharedDigitPoolSignalRequiresAnEquationAndOperator() throws {
    let catalogue = try MathSkillCatalogue.load()
    let skill = try XCTUnwrap(catalogue.skills.first { $0.name == "horizontal-digit-constraints" })
    let method = MathTeachingMethod(id: skill.sourceID, versionID: "digit-pool-signal",
      title: skill.title, category: skill.category, instructions: skill.instructions, createdAt: Date())
    for (hint, expected) in [
      ("0、1、2、3、4、5、7各一次，□□+□=□×□=□□", true),
      ("1至9各一次，九个位置。", false),
      ("1至9各一次，□=□。", false),
      ("□□+□=□×□=□□", false)
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertEqual(candidates.contains { $0.id == skill.sourceID }, expected, hint)
    }
  }

  func testChapter416SharedPoolsAndSquaresRecallExactMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "horizontal-digit-constraints" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "chapter416", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in [
      "ABA×ABA=CCDCC，同字同数异字异数，问ABCD。",
      "1至9填三个的九框：□+□=□，□−□=□，□×□=□，共用数字池。",
      "0、1、2、3、4、5、7各一次，□□+□=□×□=□□。",
      "ABC×ABC=ABDBD，同字同数异字异数，求最后乘积。",
      "全式1至9各一次其中5已印：□×□=5□；□□×□÷□=□，共用数字池。",
      "九个框填1至9，□−□=1，□+□=9，□□÷□=9，□×□=9；框外1/9不占框库存。",
      "1至7填□×□=□÷□=□+□−□，各一次，公共值未知。",
      "0至6各一次组合一或两位数，○×○=□=○÷○，五个数共七数字，问方框数。",
      "1至9填九框□+□=□□□÷□□□+1=6−□，问被除数。",
      "小山羊×小山+小羊=2000，三字分别不同数字，问小山羊。",
      "两个共用字：迎+春×春=迎春；(迎+杯)×(迎+杯)=迎杯，问迎+春+杯。",
      "两个共用异数字：汶×川×汶川+地+震震=2008；四×川+四川=55，问四川地震。",
      "2至9各一次填(□+□+□+□)÷(□+□+□)=□。",
      "全式1至9各一次固定9/5已印，□×□=9□□÷5□=□□。左边是两个一位数。",
      "1至4四字异数：仔细×仔细+细=细心×心算，问仔细心算。",
      "0至9十字母互异：D−K×L=F，E×E=HE，C÷K=G，K个H连乘=B，问A+C。",
      "1至9□□×□÷□=□□□−□−□，左四框填偶数，右五框填奇数，各数字一次。",
      "ABCBD×ABCBD=CCCBCCBBCB，同字同数异字异数，A=8，求B+C+D。"
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testChapter415LetterAndSparseColumnSourcesRecallExactMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "chapter415-first", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (name, hint) in [
      ("column-digit-constraints", "HORSE+HORSE=RABBIT，同字同数异字异数，求和。"),
      ("column-digit-constraints", "FORTY+FIFTEEN+FIFTEEN=SEVENTY，同字同数异字异数，给两种填法。"),
      ("column-digit-constraints", "ABCDE+FGHI=CJGBGA，同字同数异字异数，问结果。"),
      ("column-digit-constraints", "SHOW+ME+THE=MONEY，同字同数异字异数，MONEY最大多少？"),
      ("column-digit-constraints", "四个两位数竖式求和，每列从上到下连同结果位是0至9顺时针圆环连续五数字，求结果。"),
      ("column-digit-constraints", "1至9填九格含已给7/6/3，□7×□=6□，共用积再加□□=□3，两算式同时成立。"),
      ("column-digit-constraints", "三位乘三位竖式十空填0至9各一次，部分积3□08、□504、7□2，积□3248。"),
      ("column-digit-constraints", "□1□乘两位数竖式，个位部分积四位，十位部分积1□□，总积□□0□。"),
      ("column-digit-constraints", "□□5乘三位竖式，仅显示部分积1□□□和左移两列的□□□，总积1□□05。"),
      ("column-digit-constraints", "□7□乘两位竖式，部分积□□5与□□93，积1□□□□。"),
      ("column-digit-constraints", "AB乘CD竖式，同字同数异字异数，部分积1□□和1□D，总积□□D8，求全部字母赋值。"),
      ("column-digit-constraints", "□□5乘4□竖式，部分积3□□和□2□□，总积1□□□□，求两种填法所得乘积之差。"),
      ("column-digit-constraints", "□恭□乘1贺□竖式，同字同数异字异数，部分积9新□、□□9年、□□8，总积□□年□□，求积。"),
      ("column-digit-constraints", "巴西法国乘自身的竖式，八个汉字异数；部分积□□□□国、争夺□□、□□□法位移0、2、3，总积□冠军□□□□，求八字表示的数。"),
      ("column-digit-constraints", "三位数乘3□2竖式，部分积□9□、4□5□、□□□5，总积六位，补全。"),
      ("column-digit-constraints", "四位乘四位竖式，四条部分积均五位且末位1、9、9、9，总积八位末四位9991，补全。"),
      ("long-division-reconstruction", "除法竖式：除数□2，四位被除数，三位商；首积□2，第二段□4□减三位数，末段□□2减□9□余0，求全部填法。"),
      ("long-division-reconstruction", "小数除法竖式：三位整数除数，三位整数两位小数被除数，商□.□1，依次减234、351和三位数，余0，问被除数。"),
      ("long-division-reconstruction", "除法竖式：6除4□□□，三位商，首减两位数，中间两位段减一位数，末两位段减两位数余0，十五空最多几个偶数？"),
      ("long-division-reconstruction", "竖式1÷8，原数没有小数位，继续补零精确除完，不能将商写成125。"),
      ("long-division-reconstruction", "小数除法竖式0.01÷2，只处理到十分位余0，但还有原来的百分位1未读，能判精确商0吗？"),
      ("long-division-reconstruction", "小数竖式0.04÷2，十分位零商是否可以删掉？"),
      ("long-division-reconstruction", "字母除法竖式：AB除DEFGF，商CBA，部分积BH、AAH、IF，中间段AAG，最后余0，A至I异数，问被除数。"),
      ("long-division-reconstruction", "除法竖式两位除数，八位被除数□□□□□5□1，商4□5□□□；显示非零减数对齐第3/4/5/7/8位，位宽2/2/3/3/3，补全含零商。"),
      ("long-division-reconstruction", "除法竖式三位除数、八位被除数、商□7□□□，非零减数对齐第4/5/6/8位，位宽4/3/3/4，后续被除段位宽3/4/4，补全。"),
      ("long-division-reconstruction", "两位除数的长除法竖式，七位被除数□0□□□□□，商□7□□3；非零减数对齐第3/4/6/7位，宽3/3/3/2；第二减数□4□，第三显示被除段□□4。"),
      ("column-digit-constraints", "奇偶除法竖式：奇奇6除偶偶奇奇偶，商奇奇偶；减数偶奇偶/奇偶偶/偶奇偶，中间被除段奇奇奇，余0。奇偶只是类别。"),
      ("long-division-reconstruction", "奇偶除法竖式：奇奇6除偶偶奇奇偶，商奇奇偶；减数偶奇偶/奇偶偶/偶奇偶，中间被除段奇奇奇，余0。奇偶只是类别。"),
      ("long-division-reconstruction", "小数除法竖式两位整数除数、三位整数被除数，商一位整数三位小数；四段被除段宽3/2/3/2，减数宽2/2/3/2，最后余0。"),
      ("seven-segment-digit-restoration", "七段电子数字乘法算式笔画模糊，三位乘两位，两条部分积三位，积四位；按原图可靠黑段恢复，其他笔画未知，不允许移动实线。"),
      ("long-division-reconstruction", "长除法竖式：六位除数□□□□7□，商□□7□□，十位被除数□□7□□□□□□□；五个非零减数宽6/7/6/7/6，中间固定7按原图落位。"),
      ("long-division-reconstruction", "两位除数长除法，7□2被除数，商2□，首减6□，落位1□2，末减1□2，余0，求全部填法。"),
      ("long-division-reconstruction", "除法竖式：除数□□2，被除数□9□□，两位商；首减5□8、落位□6□、末减6□□余0，求被除数除数商之和。")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testChapter414AverageBranchesRecallWithoutForcingDiagrams() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "averages" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "chapter414", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in [
      "射击10枪，靶上2/4/6/8/10分区分别2/4/2/2/0个弹孔，求平均分。",
      "甲车间57人平均132，乙平均163，合平均144，乙多少人？",
      "五天产量81、74、6开头破损、末位7破损、69，平均73，求第三四天。",
      "六次测验后四次平均比总平均高3，第1/2/6次平均比总平均低3.6，前五次平均比总平均差多少？",
      "1、2、3起连续若干自然数，擦去一个后剩余平均10.8，擦去几？",
      "一等奖10人末4人移入原20人二等奖，两组平均分别提高3分和1分，原两均分差？",
      "男生平均比总平均高2，女生平均比总平均低1，男总942女总1800，男女各多少人？",
      "裁判评分最高10，平均9.64，分别只去最高均9.60、只去最低均9.68，最低最少多少及人数？"
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testChapter413SourceBranchesRecallTheirExactMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "chapter413", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (name, hint) in [
      ("repeated-digit-blocks", "10个9乘12345；核位宽和借位。"),
      ("repeated-digit-blocks", "10个3乘9个3后接4。"),
      ("repeated-digit-blocks", "28+208+2008至末项2后100个0再接8；98+998至末项100个9接8，两问。"),
      ("repeated-digit-blocks", "3+33+333至50个3求和。"),
      ("repeated-digit-blocks", "999999×222222+333333×333334。"),
      ("repeated-digit-blocks", "1981×198319831983−1982×198119811981。"),
      ("repeated-digit-blocks", "100个9平方加1后100个9；20个3乘20个6，两问。"),
      ("repeated-digit-blocks", "2000个9乘2000个8除2000个6，求数位和。"),
      ("repeated-digit-blocks", "40个4减20个6，加20个8后接10个0。"),
      ("repeated-digit-blocks", "2000个8平方减2000个1平方。"),
      ("repeated-digit-blocks", "300个8乘300个3，求数位和。"),
      ("repeated-digit-blocks", "3+3.3+3.33至末项小数部分99个3，高清括号仅包小数部分。"),
      ("repeated-digit-blocks", "99个4后6点99个2后4是平方，求完整小数根。"),
      ("repeated-digit-blocks", "99个1与100个1分别平方，求两次数位和。"),
      ("place-value-and-decimals", "去掉小数部分所得整数加原数4倍等于27.6，求原数。")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许本题拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
    let repeated = try XCTUnwrap(catalogue.skills.first { $0.name == "repeated-digit-blocks" })
    let ordinary = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，允许拓展知识。", textHint: "计算1234+5678。")
    XCTAssertFalse(ordinary.contains { $0.id == repeated.sourceID })
    let star = try XCTUnwrap(catalogue.skills.first { $0.name == "finite-game-strategy" })
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，不用方程。", textHint: "五角星15条小线段，甲乙轮流移动，边不能重复，交点可重到，无路可走者输，谁有必胜策略？")
    XCTAssertTrue(candidates.contains { $0.id == star.sourceID })
  }

  func testPrefixMirrorAndCapacitySourceStemsRecallTheirMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "response-capacity-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (name, hint) in [
      ("finite-game-strategy", "2008个小方格排成一行，甲乙轮流放，甲隔一个位置、乙必须紧挨，乙已在最左第一个放好，谁放不了谁输，谁有必胜策略？"),
      ("geometric-mirror-response-games", "两人轮流在一个圆桌面放同样大小硬币，不许重叠，谁放最后一个让对方无处放谁赢。先放者如何取胜？"),
      ("shared-corridor-capacity-costs", "10个村沿县城公路，粗管供所有村每千米8000元，细管只能供1村每千米2000元。怎样搭配连接水管最节省总费用？")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(name): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testOriginalGameRulesRecallRevisedFiniteGameMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "finite-game-strategy" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "game-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["甲黑棋先占井字棋中心，乙第一枚白棋放哪里可以不败？两人轮流放棋，横竖斜三个连线赢。",
                 "黑板写1到2009，甲先乙后轮流擦一个数，最后两数奇偶不同甲赢，否则乙赢，谁有必胜策略？",
                 "4列3行方格，左下A右上B，甲先乙后轮流移动，只能上右或右上1步，到B的人赢。",
                 "7列6行方格，甲先乙后轮流上右斜移动，1步与任意多步，到右上B赢，策略分别是什么？",
                 "阶梯棋盘左下开始，甲乙轮流移动棋子，上右或右上任意多格，把棋子移到右上者输，甲先能否必胜？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testShortestWeightedAndRequiredVisitSourcesRecallMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "weighted-shortest-routes-and-required-visits" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "route-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["贪吃蛇从左下角沿格线爬行，要吃三个星，最少爬多少厘米？请画路线。",
                 "道路图每段旁边数字表示行走分钟，卡莉娅从A出发到B最快需要多少分钟？",
                 "小唐从县城出发，经过甲乙丙丁戊各乡镇至少一次，最后回县城，公路旁数字为时间，最少多少分钟？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testSharedResourceAndPrecedenceSourceRecallsCompleteMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "shared-resource-precedence-scheduling" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "resource-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["小高要炒菜煮饭烧水，煤气炉只有一个灶，电饭锅煮饭，切菜4佐料4热锅2热油2炒菜4，洗壶2烧水15灌水2，淘米4煮饭18，各道工序如何安排最少多久？",
                 "洗水壶1分钟，烧水15分钟，洗茶壶1洗杯1拿茶叶2，怎样安排同时做的事最少多久完成？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testParallelEquipmentSourceQuestionsRecallWholeTaskMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "parallel-identical-machine-makespan" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "parallel-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["水房有两个水龙头，五人同时需要用水，刷牙5洗脸2洗头10浇花1洗衣服15分钟，最早何时全部用完？",
                 "三人准备在三个同样效率的车床上车七零件，4、5、6、6、8、9、9分钟，同时工作合理分工最少多久完成？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
    let denied = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，不允许拓展知识。", textHint: "两个水龙头五个任务最早用完，允许拓展知识。")
    XCTAssertFalse(denied.contains { $0.id == expected.sourceID })
  }

  func testWholePackAndTransportOriginalQuestionsRecallMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "purchase-transport-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("面包5个一袋8元，3个一袋5元，不拆开零售，47位同学每人发1个最少花多少钱？", "whole-pack-integer-purchasing"),
      ("47人每人1支红笔1支蓝笔，5支一包或3支一包，不能打开零售，红61/40元蓝70/47元，最少多少钱？", "whole-pack-integer-purchasing"),
      ("环形公路四个仓库库存40、5、35、0吨，调运至各20吨，每段10公里，每吨公里2元，最少运费？", "small-network-transport-costs"),
      ("北京上海供应车床10台6台，分配给武汉11台西安5台，运费表北京500/600，上海700/1000，总运费最少多少？", "small-network-transport-costs")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testSimplePathHistoryConstraintRecallsEligibleSnapshot() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "simple-paths-with-visited-state" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "simple-path-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["小甲虫从A点沿线段爬到B点，不能重复经过任何一点，问有多少种走法？",
                 "无向路网S-A、S-B、A-B、A-T、B-T，从S走到T，禁止重复顶点，求全部路径数。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
    let forbidden = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，不允许拓展知识。", textHint: "不能重复经过任何一点，从A爬到B，允许拓展知识。")
    XCTAssertFalse(forbidden.contains { $0.id == expected.sourceID })
  }

  func testCountingChoiceAndBoardSourceBranchesRecallMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "counting411-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("用红蓝两种颜色给九个小圆圈染色，竖轴五个圆，两侧各两个，求任意染色与左右对称染色有多少种。", "counting-by-cases-and-stages"),
      ("餐厅2种主食3种主菜各点1种，1种汤2种甜点可点可不点，种类不限，有多少点菜方法？", "counting-by-cases-and-stages"),
      ("3名木匠3名电工另有1人两种工作都能做，从7人挑4人做2木2电有多少选法？", "counting-by-cases-and-stages"),
      ("4枚相同棋子放入4×4方格，每行每列至多1枚，共多少放法？", "restricted-arrangements"),
      ("阶梯方格表放5枚相同棋子，每行每列恰1枚，各行长度2,3,4,5,5，共多少放法？", "restricted-arrangements"),
      ("3×4方格放4枚相同棋子每列至多1枚，再问互不相同棋子的放法。", "restricted-arrangements")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testGeometricTableSourceQuestionsRecallEligibleMethods() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "geometric-table-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("方格数表中1,3,6,10,15沿螺旋排列，求问号处的数。", "layered-table-indexing"),
      ("将1至400填入三角形数表的小三角格，第1行1个，第2行3个，求第15行中间数、第12行白格和、前8行阴影白色差。", "layered-table-indexing"),
      ("从1开始自然数按三角轮廓螺旋排成40行数表，求第1行、第20行和第35行最大数最小数之和。", "layered-table-indexing"),
      ("25个同样大小的等边三角形拼成大三角形，每个顶点标数，任何相邻两个小三角形构成菱形的两组相对顶点和都相等，三个大角100、200、300，求所有顶点数之和。", "triangular-grid-rhombus-propagation")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testInterleavedArithmeticAndPeriodicSourceQuestionsRecallMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "sequences-and-number-tables" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "interleaving-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["观察数列1,1,4,2,7,3,10,1,13,2,16,3,…,100，求多少项以及所有项的总和。",
                 "观察数列1,100,2,98,3,96,2,94,1,92,2,90,3,88,…,0，求多少个2和所有项总和。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testTranslatedWindowAndSnakeExtremaAreRecalled() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "translated-table-windows-and-fixed-sum-extrema" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "window-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for hint in ["七列数表从1向右排列，3×3窗口内九数之和2016，这个窗口是否存在？",
                 "自然数排成15列蛇形表，上下相邻两数和391，求这两个数的乘积最小值。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testIncidenceAndRecursiveWindowStructuresRecallEligibleSnapshots() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "incidence-cycle-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("将1至9填入图中9个圆，图中所有7个三角形的3个顶点上的数之和都等于15，已给5、6、9，补全。", "incidence-sum-constraints-and-extrema"),
      ("将1至8填入大小正方形8个圆，每个三角形的3个顶点数之和相等，小正方形顶点和是大正方形顶点和的一半。", "incidence-sum-constraints-and-extrema"),
      ("大三角形分成9个小三角形，填入1至9，靠近三条边的每5个数的和相等，最大可能是多少，并给一种填法？", "incidence-sum-constraints-and-extrema"),
      ("将1至9填入五个交叠圆的9个区域，使每个圆内数字和相等，公共和最大和最小是多少？", "incidence-sum-constraints-and-extrema"),
      ("1至7填入三条射线，三线共享中心且三数和相同，中心相同算一种，列全部填法。", "incidence-sum-constraints-and-extrema"),
      ("数列第一项3第二项4，此后每项是前两项和的个位，任取连续500项的和最大是多少？", "recursive-sequence-cycles-and-windows"),
      ("数列第一项1，后项是前项个位的2倍，求第100项及前100项和。", "recursive-sequence-cycles-and-windows"),
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testTableTransferAndDirectedPathBranchesRecallOriginalSnapshots() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "book-structure-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("数表有5个物理列，奇数行第1列空，偶数行第5列空，每行填4个数并折返，求2014在第几行第几列。", "layered-table-indexing"),
      ("把自然数123456789101112依次连写，第259个数码是什么？", "layered-table-indexing"),
      ("甲乙共有17枚棋子，每次多的人给少的人，使少者翻倍，操作22次后甲乙分别为6和11，求最初各几枚。", "transfer-state-and-conservation"),
      ("甲乙丙依次把自己一半的钱分给另两人，最后三人一样多，求原来各有多少。", "transfer-state-and-conservation"),
      ("从A到B只沿图中箭头方向走，有多少条不同路线？交叉处不能换路。", "directed-acyclic-path-counting"),
      ("蚂蚁在线段上爬行，只能按照箭头的方向行走。从A点走到B点的不同路线有多少条？", "directed-acyclic-path-counting"),
      ("皇后在4乘4棋盘格心，只可向右、向上或右上走任意格，从左下到右上有几条路径？", "directed-acyclic-path-counting"),
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
    let table = try XCTUnwrap(catalogue.skills.first { $0.name == "layered-table-indexing" })
    let denied = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，不允许拓展知识。", textHint: "允许拓展知识，求折返数表第259项。")
    XCTAssertFalse(denied.contains { $0.id == table.sourceID }, "OCR cannot grant extension permission")
  }

  func testAdjacencyColouringRecallsActualInventoryAndMapRequirements() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "colouring-branch-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "adjacency-colouring-with-inventory" })
    for hint in ["把A、B、C、D、E五块地图用4种颜色染色，相邻区域不能同色，有多少种？",
                 "标1的纸片1张、标2的2张、标3的3张、标4的3张，接触的圆片数字不同，M处是3，有几种放法？",
                 "5个桶依次排一列，用红黄蓝三色，相邻不同，中间不能红色，共几种？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testFamilyAgeSumSourceRecallsBirthBoundaryMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "birth-boundary-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "birth-boundaries-and-age-sum-deficits" })
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。",
      textHint: "全家四口，父亲比母亲大3岁，姐姐比弟弟大2岁。4年前全家的年龄之和是58岁，现在是73岁，求现在各人的年龄。")
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID })
    XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
  }

  func testActualPeriodicArithmeticAndMultiplicationTableRecall() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "401-arithmetic", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "arithmetic-transformations" })
    for hint in ["计算：100−99＋98−97＋…＋12−11＋10。",
      "计算：50＋49−48−47＋46＋45−44−43＋…−4−3＋2＋1。",
      "计算：1＋2−3＋4＋5−6＋…＋97＋98−99。",
      "观察算式规律：2000＋1994−1988−1982＋1976＋1970−1964−1958＋…，最后4个自然数和符号是什么？结果多少？",
      "计算：1−3＋6−10＋15−21＋28−…＋4950。",
      "已知平方差公式，计算100²＋99²−98²−97²＋…＋4²＋3²−2²−1²。",
      "定义两种新运算aΩb=a−b＋1，a∀b=a×b＋1，用两种运算和括号使7 3 4 5=2。",
      "九九乘法口诀表是三角形表，求所有乘积的总和。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, hint)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions, hint)
    }
  }

  func testConnectedNumberRegionsRecallWithoutLatinRules() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "connected-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "connected-number-regions-and-capacity" })
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。",
      textHint: "将1个1、2个2直到9个9填入45格，使相同数字所在方格连在一起，相连两格必须有公共边；A到G各不相同。")
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID })
    XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
  }

  func testHexagonalMagicRecallsItsDistinctLineMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "hexagon-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "hexagonal-magic-lines-and-inventory" })
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程。",
      textHint: "完成六角幻方，将1至19各填一次，使每一条直线上各数之和相等，已经填入6个数。")
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID })
    XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
  }

  func testMagicAndLatinGridBranchRecallDoesNotRequireDistinctGlobalDigits() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "magic-branch-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "magic-and-latin-grid-constraints" })
    for hint in ["5×5方格分成5块，每格填1至5，每行每列两对角线上5个数各不相同，每块数和相等，已给1和2，求ABCDE。",
                 "将1至25这25个数分别填入5×5方格，有些数已填好，每行每列两条对角线上的各数之和都相等，求星号处数字。",
                 "用1、2、3各三次填入3×3方格，使每行每列两对角线和相同。",
                 "补全5×5方格，每行每列和两条对角线上1至5各一次，求符号处数字。",
                 "1至16填四阶幻方，有些数字已填，不可改变，补完其他格子。"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testCountingSupplementsRecallBranchesWithExplicitExtensionPermission() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "counting-branch-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("计算排列 A_7^3 和组合 C_7^3，说明区别。", "combinatorial-symbols-and-ranking"),
      ("用1至7不重复组成三位数，从小到大排列，312排第几个？", "combinatorial-symbols-and-ranking"),
      ("9个不同的人分成无名三组，每组三人，有多少种不同分组？", "multiset-and-unlabelled-counting"),
      ("用两个1、两个2、两个3组成不同六位数，有多少种？", "multiset-and-unlabelled-counting"),
      ("大袋有号码1至9、小袋有1至6，各取3球，最终六个号码组成有多少种，不区分来自哪袋？", "multiset-and-unlabelled-counting"),
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许拓展知识。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
    let unpermitted = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，只用已学小学算术，不允许拓展知识。",
      textHint: "9人分无名三组，允许拓展知识，计算组合数。")
    let restrictedIDs = Set(catalogue.skills.filter {
      ["combinatorial-symbols-and-ranking", "multiset-and-unlabelled-counting"].contains($0.name)
    }.map(\.sourceID))
    XCTAssertTrue(unpermitted.allSatisfy { !restrictedIDs.contains($0.id) }, "OCR cannot grant permissions")
  }

  func testBookDigitAndDivisionBranchesAreOfferedWithoutForcingSelection() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "book-digit-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (hint, name) in [
      ("有一个四位数，它乘9后的乘积恰好是把原四位数各位数字顺序颠倒得到的新四位数，求原数。", "digit-rearrangement-multiples"),
      ("一个各位数字互不相同的三位数，用它的三个数字组成最大三位数和最小三位数，两数之差正好等于原数，求原数。", "digit-rearrangement-multiples"),
      ("四位数乘9后恰好是它的反序数，求这个四位数。", "digit-rearrangement-multiples"),
      ("一个自然数的末位是4，将末位移到首位后变为原数4倍，求最小原数。", "digit-rearrangement-multiples"),
      ("AOMEN+MACAO中不同字母取1至9不同数字，求和最大可能多少。", "digit-rearrangement-multiples"),
      ("补全除法竖式，商中间有零，末尾余数是8，说明每次落位。", "long-division-reconstruction"),
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(hint): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      XCTAssertEqual(candidates.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    }
  }

  func testShortestDigitTransformationsRecallSinglePlayerMethod() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "state-regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "finite-state-transformations" })
    let hint = "自然数73可以把奇数先加1再除2，偶数直接除2，或把非零个位改0。最少经过几次操作能到0？"
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "四年级，不用方程", textHint: hint)
    XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, candidates.map(\.title).joined(separator: "、"))
    XCTAssertLessThanOrEqual(candidates.count, 7)
    let edited = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程",
      textHint: "给定6595，口令7表示插入一个数字使新数尽量大，8表示去掉一个数字使新数尽量大。依次8→7→8→7→8→8变换后的六数之和？")
    XCTAssertTrue(edited.contains { $0.id == expected.sourceID })
    XCTAssertEqual(edited.first { $0.id == expected.sourceID }?.instructions, expected.instructions)
    let game = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程",
      textHint: "两人轮流拿1至3枚棋子，拿最后一枚者赢，先手怎样保证必胜？")
    XCTAssertTrue(game.contains { $0.title == "有限博弈与必胜策略" })
    XCTAssertFalse(game.contains { $0.id == expected.sourceID }, "A winning path is not an adversarial strategy")
  }

  func testGenericTeachingInstructionsDoNotSupplyProblemEvidence() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let instruction = "4年级。使用小学算术解释并验算。不要补题意，不要方程；条件不足时不选择直接求唯一数值的技能。"
    for hint in ["", "43", "Good morning.", "请翻译这句英语而不做数学分类：Good morning."] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: instruction, textHint: hint)
      XCTAssertTrue(candidates.isEmpty, "\(hint): \(candidates.map(\.title))")
    }
    let stem = "一个数乘10，得到的数比原来的数大72。原来的数是多少？"
    let fromHint = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: instruction, textHint: stem)
    XCTAssertTrue(fromHint.contains { $0.title == "差倍问题" })
    let fromQuestion = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: instruction + "\n" + stem, textHint: "")
    XCTAssertTrue(fromQuestion.contains { $0.title == "差倍问题" }, "Actual questions typed into the prompt must still be retrieved")
  }

  func testAverageAndOverlapHaveEligibleSolutionCandidates() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    for (stem, expected) in [
      ("2人平均80分，3人平均90分，5人平均几分？", "平均数问题"),
      ("美术组25人，音乐组18人，两组都参加7人，参加至少一组有多少人？", "重叠问题")
    ] {
      let result = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "4年级。不要使用方程；用小学算术解释并验算。", textHint: stem)
      XCTAssertTrue(result.contains { $0.title == expected }, result.map(\.title).joined(separator: "、"))
      for method in result { XCTAssertEqual(method.instructions, methods.first { $0.id == method.id }?.instructions) }
    }
  }

  func testLanguageContextDoesNotSuppressAnActualMathRequest() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let combined = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "先翻译成英文，再用小学算术解题，不使用方程。",
      textHint: "红绳与蓝绳共有20米，红绳比蓝绳长4米。两根各多长？")
    XCTAssertTrue(combined.contains { $0.title == "和差问题" })
    let exam = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: "英语考试中2人平均80分，3人平均90分，5人平均几分？", textHint: "")
    XCTAssertTrue(exam.contains { $0.title == "平均数问题" })
  }

  func testReverseVisualLinksCannotRestoreEditedOrRevokedProjectMethods() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project-version", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let visual = try project("venn-overlap-diagram")
    let solution = try project("overlap-counting")
    let query = "美术组25人，音乐组18人，两组都参加7人，至少参加一组的有几人？"
    let original = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程", textHint: query)
    XCTAssertTrue(original.contains { $0.id == solution.id }, original.map(\.title).joined(separator: "、"))
    let changed = MathTeachingMethod(id: solution.id, versionID: "edited-solution", title: solution.title,
      category: solution.category, instructions: "用户修改后的独立方法内容，不能沿用旧项目的适用描述和关联授权。", createdAt: solution.createdAt,
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    let edited = MathLocalSkillRetrieval.retrieve(methods: methods.map { $0.id == changed.id ? changed : $0 }, requirements: "四年级，不用方程", textHint: query)
    XCTAssertFalse(edited.contains { $0.id == solution.id }, "A linked title alone must not attach edited project prose")
    let removed = MathLocalSkillRetrieval.retrieve(methods: methods.filter { $0.id != solution.id }, requirements: "四年级，不用方程", textHint: query)
    XCTAssertFalse(removed.contains { $0.id == solution.id }, "A revoked/absent method must not be reconstructed from a visual link")
    let injectedTarget = custom("injected-link-target", title: "待审边界算法", body: "opaque unrelated implementation")
    let changedVisual = MathTeachingMethod(id: visual.id, versionID: "edited-visual", title: visual.title,
      category: visual.category, instructions: "音乐与美术两组都参加，观察交集。[[待审边界算法]]", createdAt: visual.createdAt,
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    let untrusted = MathLocalSkillRetrieval.retrieve(methods: [changedVisual, injectedTarget], requirements: "四年级，不用方程", textHint: "音乐与美术两组都参加")
    XCTAssertFalse(untrusted.contains(injectedTarget), "An edited visual must not create trusted dependency edges")
  }

  func testDiscoveryIndexDoesNotRecallDigitExtremaFromGenericExampleWords() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    for hint in ["一个数乘10，得到的数比原来的数大72。原来的数是多少？",
                 "一个数扩大到原来的8倍，比原数增加63。求原数。"] {
      let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程", textHint: hint)
      XCTAssertTrue(result.contains { $0.title == "差倍问题" }, result.map(\.title).joined(separator: "、"))
      XCTAssertFalse(result.contains { $0.title == "u 法和 n 法" }, result.map(\.title).joined(separator: "、"))
      for candidate in result { XCTAssertEqual(candidate.instructions, methods.first { $0.id == candidate.id }?.instructions) }
    }
    let extrema = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程",
      textHint: "3、6、7、4各用一次组成两位数乘两位数，求最大和最小的积。")
    XCTAssertTrue(extrema.contains { $0.title == "u 法和 n 法" })
  }

  func testOptionalCorpusRetrievalAudit() throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_RETRIEVAL_CORPUS_AUDIT"] else {
      throw XCTSkip("Explicit local corpus retrieval audit")
    }
    let catalogue = try MathTeachingReviewCatalogue.load()
    let methods = catalogue.catalogue.skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    var rows: [[String: Any]] = []
    for item in catalogue.cases {
      let requirements = "\(item.grade ?? 4)年级。\(item.user_constraint)"
      let eligible = MathMethodMatcher.eligibleMethods(methods, question: requirements, catalogue: catalogue)
      let eligibleNames = Set(eligible.compactMap { catalogue.catalogue.discoveryMetadata(for: $0)?.name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: requirements, textHint: item.stem)
      let names = candidates.compactMap { catalogue.catalogue.discoveryMetadata(for: $0)?.name }
      let expected = Set(item.expected_methods).intersection(eligibleNames)
      rows.append(["id": item.id, "kind": item.kind, "expectedEligible": expected.sorted(),
        "candidates": names, "anyExpectedRecalled": !expected.isDisjoint(with: names),
        "candidateBodyBytes": candidates.reduce(0) { $0 + $1.instructions.utf8.count }])
    }
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path))
    XCTAssertEqual(rows.count, catalogue.cases.count)
  }

  func testOptionalSystemSemanticFeasibilityAudit() throws {
    guard let path = ProcessInfo.processInfo.environment["MATH_SEMANTIC_RETRIEVAL_AUDIT"] else {
      throw XCTSkip("Explicit system semantic feasibility audit; no production change")
    }
    let embedding = try XCTUnwrap(NLEmbedding.sentenceEmbedding(for: .simplifiedChinese))
    let catalogue = try MathTeachingReviewCatalogue.load()
    let methods = catalogue.catalogue.skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    var vectors: [String: [Double]] = [:]
    for skill in catalogue.catalogue.skills {
      vectors[skill.sourceID] = embedding.vector(for: skill.title + "。" + skill.description)
    }
    func similarity(_ a: [Double], _ b: [Double]) -> Double {
      let denominator = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
      return denominator > 0 ? zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } / denominator : 0
    }
    var rows: [[String: Any]] = []
    let probes: [(String, String, String)] = catalogue.cases.map { ($0.id, $0.stem, "\($0.grade ?? 4)年级。\($0.user_constraint)") } + [
      ("actual-times-ten", "一个数乘10，得到的数比原来的数大72。原来的数是多少？", "四年级，不用方程"),
      ("heldout-times-eight", "一个数扩大到原来的8倍，比原数增加63。求原数。", "四年级，不用方程")]
    for (id, stem, requirements) in probes {
      let vector = try XCTUnwrap(embedding.vector(for: stem))
      let eligible = MathMethodMatcher.eligibleMethods(methods, question: requirements, catalogue: catalogue)
      let ranked = eligible.compactMap { method -> (MathTeachingMethod, Double)? in
        guard let document = vectors[method.id] else { return nil }
        return (method, similarity(vector, document))
      }.sorted { $0.1 > $1.1 }
      let solution = ranked.filter { MathMethodMatcher.singleCallRolePolicy(for: $0.0, catalogue: catalogue).roles.contains("solution") }.prefix(5)
      let visual = ranked.filter { MathMethodMatcher.singleCallRolePolicy(for: $0.0, catalogue: catalogue).roles.contains("visual") }.prefix(2)
      let candidates = Array(solution) + Array(visual)
      let names = candidates.compactMap { catalogue.catalogue.discoveryMetadata(for: $0.0)?.name }
      let item = catalogue.cases.first { $0.id == id }
      let eligibleNames = Set(eligible.compactMap { catalogue.catalogue.discoveryMetadata(for: $0)?.name })
      let expected = Set(item?.expected_methods ?? ["difference-and-ratio"]).intersection(eligibleNames)
      rows.append(["id": id, "kind": item?.kind ?? "probe", "expectedEligible": expected.sorted(),
        "candidates": names, "anyExpectedRecalled": !expected.isDisjoint(with: names),
        "ranked": ranked.map { ["name": catalogue.catalogue.discoveryMetadata(for: $0.0)?.name ?? "", "similarity": $0.1] as [String: Any] }])
    }
    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path))
  }

  func testUnlabelledTotalRatioStemsRecallEligibleSumRatioMethod() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    for hint in ["杏树和桃树共248棵，桃树是杏树的3倍。杏树、桃树各有多少棵？",
                 "红球和蓝球合计80个，蓝球数量是红球的4倍。两种球各有多少个？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.title == "和倍问题" }, candidates.map(\.title).joined(separator: "、"))
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }
  func testUnlabelledRectangleSumAndDifferenceRecallsMethodWithoutForcingAdoption() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    for hint in ["长方形长和宽之和是18厘米，长比宽多2厘米。求长方形面积。",
                 "红绳与蓝绳的和是20米，红绳比蓝绳长4米。两根各多长？"] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程", textHint: hint)
      XCTAssertTrue(candidates.contains { $0.title == "和差问题" }, candidates.map(\.title).joined(separator: "、"))
    }
  }

  private func custom(_ id: String = "custom", title: String = "盈亏分配",
    body: String = "每人分配物品，两次分配的盈亏差额除以每人分配差，得到人数。",
    grade: Int = 4, equation: MathTeachingPermissions.Equation = .notRequired,
    extensionPermission: MathTeachingPermissions.Extension = .none) -> MathTeachingMethod {
    .init(id: id, versionID: "approved-immutable-version", title: title, category: "应用题",
      instructions: body, createdAt: Date(timeIntervalSince1970: 0), teachingPermissions:
        .init(minimumGrade: grade, equationRequirement: equation, extensionRequirement: extensionPermission))
  }
  private func project(_ name: String) throws -> MathTeachingMethod {
    let skill = try XCTUnwrap(MathSkillCatalogue.load().skills.first { $0.name == name })
    return .init(id: skill.sourceID, versionID: "project-version", title: skill.title,
      category: skill.category, instructions: skill.instructions, createdAt: Date())
  }
  func testFormattingRequirementsDoNotRecallIntervalSkillsForAnEdgeTrail() throws {
    let methods = try MathSkillCatalogue.load().skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let learned = custom("learned-trail", title: "一笔画的奇点与路径检查",
      body: "确认所有线在同一连通图。数每点连接的线，奇数条叫奇点。两个奇点可从一个到另一个，不抬笔每条边恰一次。逐边检查完整路径，不重复不遗漏。",
      extensionPermission: .explicitPermission)
    let request = "小学四年级，明确允许拓展方法，不使用方程。请参照原图，使用适用方法并逐边验算；末尾单独一行写‘最终路径：E→F→…’，用实际点名替代示例，不要在这一行写其他文字。"
    let hint = "小学拓展一笔画：五点E、F、G、H、I。边为EF、FG、GH、HI、IE、EG。不抬笔，每条边只画一次，能否画完？请给出完整路径。"
    let candidates = MathLocalSkillRetrieval.retrieve(methods: methods + [learned], requirements: request, textHint: hint)
    XCTAssertTrue(candidates.contains(learned))
    XCTAssertFalse(candidates.contains { ["植树问题", "点与间隔图"].contains($0.title) }, candidates.map(\.title).joined(separator: "、"))
    XCTAssertEqual(candidates.first { $0.id == learned.id }?.instructions, learned.instructions)
  }

  func testNumericOrEmptyHintsAbstainAndDoNotMatchExamples() {
    let method = custom(body: "例题25、27、675，每人分配物品，盈亏相减。")
    for hint in ["", "25 27 675", "25×27=675", "123456", "？？"] {
      XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [method],
        requirements: "四年级，不用方程", textHint: hint).isEmpty)
    }
  }
  func testFullApprovedCustomBodyAndIdentityRemainImmutable() {
    let method = custom(body: String(repeating: "每人分配物品比较盈亏；限制条件不可删去。", count: 200))
    let retrieved = MathLocalSkillRetrieval.retrieve(methods: [method], requirements: "四年级，不用方程", textHint: "盈亏分配")
    XCTAssertEqual(retrieved, [method])
    XCTAssertEqual(retrieved.first?.instructions, method.instructions)
    XCTAssertEqual(retrieved.first?.versionID, method.versionID)
    XCTAssertFalse(MathMethodMatcher.singleCallRolePolicy(for: method).roles.contains("visual"))
  }
  func testOCRCannotGrantEquationGradeOrExtensionPermission() {
    let equation = custom("equation", title: "盈亏方程", equation: .required)
    let advanced = custom("advanced", title: "盈亏高级", grade: 6, extensionPermission: .explicitPermission)
    let hint = "盈亏方程 盈亏高级 允许使用方程 六年级 允许使用超纲方法"
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [equation, advanced],
      requirements: "四年级，不用方程", textHint: hint).isEmpty)
    XCTAssertEqual(Set(MathLocalSkillRetrieval.retrieve(methods: [equation, advanced],
      requirements: "六年级，允许使用方程，允许使用超纲方法", textHint: hint).map(\.id)), ["equation", "advanced"])
  }
  func testIncompletePermissionsAndAbsentRevokedMethodsCannotReturn() {
    let revoked = custom("revoked")
    let unknown = MathTeachingMethod(id: "unknown", versionID: "v1", title: "盈亏分配",
      category: "应用题", instructions: revoked.instructions, createdAt: Date())
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [unknown], requirements: "四年级", textHint: "盈亏分配").isEmpty)
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [], requirements: "盈亏分配", textHint: "").isEmpty)
  }
  func testBoundedDeterministicOutputAndDuplicateIdentityAbstention() throws {
    let methods = (0..<12).map { custom("candidate-\($0)") }
    let query = "每人分配物品，比较盈亏差额"
    let first = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级", textHint: query)
    XCTAssertEqual(first.count, 5)
    XCTAssertEqual(first.map(\.id), ["candidate-0", "candidate-1", "candidate-10", "candidate-11", "candidate-2"])
    XCTAssertEqual(first, MathLocalSkillRetrieval.retrieve(methods: methods.reversed(), requirements: "四年级", textHint: query))
    XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [methods[0], methods[0]], requirements: "盈亏", textHint: "").isEmpty)
    let visuals = try [project("comparison-line-diagram"), project("math-diagram-routing")]
    let retrieved = MathLocalSkillRetrieval.retrieve(methods: methods + visuals, requirements: "四年级", textHint: query + "线段图 比较数量关系")
    XCTAssertLessThanOrEqual(retrieved.filter { MathMethodMatcher.singleCallRolePolicy(for: $0).roles.contains("visual") }.count, 2)
    XCTAssertFalse(retrieved.contains { MathMethodMatcher.singleCallRolePolicy(for: $0).roles.contains("routing") })
  }
  func testRepresentativeCatalogueRecallWithoutPrimaryClaim() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    for (skill, query) in [("surplus-and-shortfall", "每人分配物品，两次分配盈亏差额与人数"),
      ("difference-and-ratio", "爸爸年龄是小明的倍数，两人年龄差不变"),
      ("distance-speed-time", "顺流速度，逆流速度，返回路程与时间")] {
      let expected = try project(skill)
      let result = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: "四年级，不用方程", textHint: query)
      XCTAssertTrue(result.contains { $0.id == expected.id }, "missing \(skill): \(result.map(\.title))")
    }
  }
  func testUnlabelledActualStemsRecordRecallAndDiscountDoesNotChoosePrimary() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let stems = [
      "今年爸爸年龄是小明的3倍，去年爸爸比小明大30岁。小明今年多少岁？",
      "从1楼走到14楼，每层楼21级台阶，一共走了多少级台阶？",
      "一次最多可玩45分钟。先顺流而下每分钟30米，再逆流而上每分钟20米。顺流行驶21分钟后返回，能按时返回吗？",
      "每名同学发25张，剩下的还能发给2名同学；每名同学发27张，正好发完。求同学人数和总张数。",
      "班级读书角买245本故事书。A书店原价12元每本，每满100元减15元；B书店原价12元每本，买8本送1本。哪里优惠？"
    ]
    for (index, stem) in stems.enumerated() {
      let result = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem)
      print("LOCAL_RETRIEVAL_STEM_\(index): " + result.map { "\($0.id):\($0.title)" }.joined(separator: " | "))
      XCTAssertLessThanOrEqual(result.count, 7)
      let expectedTitles = ["差倍问题", "植树问题", "行程问题", "盈亏问题"]
      if index < expectedTitles.count {
        XCTAssertTrue(result.contains { $0.title == expectedTitles[index] })
        if index == 1 { XCTAssertTrue(result.contains { $0.title == "点与间隔图" }) }
        if index == 2 {
          XCTAssertTrue(result.contains { $0.title == "列表法" })
          XCTAssertTrue(result.contains { $0.title == "线段图" })
          XCTAssertFalse(result.contains { $0.title == "面积图" })
        }
      } else {
        XCTAssertTrue(result.isEmpty, "Discount rules have no directly supported lexical skill here.")
      }
      // This API has no primary-method field: even the discount stem merely
      // offers candidates which the one-shot solver must independently reject.
      XCTAssertTrue(result.allSatisfy { candidate in methods.contains(candidate) })
    }
  }

  // Known regression fixtures, not fresh accuracy examples: the original run
  // omitted these applicable candidates despite readable source relationships.
  func testGuaranteeAndRepeatedInverseRecallWithoutMethodNames() throws {
    let methods = try MathSkillCatalogue.load().skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "regression", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (stem, name) in [
      ("19块巧克力分给3个人，请说明一定有人至少分到7块，但不一定有人分到8块。", "pigeonhole-principle"),
      ("31颗糖任意分给5个小朋友，说明必有一人不少于7颗。", "pigeonhole-principle"),
      ("李白带酒过三家酒店，每过一家，先将酒加一倍，再喝8两，最后恰好喝完。原来有几两酒？", "reverse-operations"),
      ("一些贴纸每次先扩大到原来的3倍，再送走12张，连续做两次后还剩6张，起初有几张？", "reverse-operations")
    ] {
      let expected = try project(name)
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem)
      XCTAssertTrue(candidates.contains { $0.id == expected.id }, "\(name): \(candidates.map(\.title))")
    }
  }

  func testStructuralRecallDoesNotLearnConceptsFromBodyExclusions() {
    let unrelated = custom("unrelated", title: "颜色辨认", body:
      "排除：抽屉原则、保证至少、等待调度、排队时间、还原逆运算、排列组合都不能采用。")
    let guarantee = custom("guarantee", title: "抽屉原则", body: "核对所有分配与容量边界。")
    let inverse = custom("inverse", title: "还原问题", body: "按逆序逐步核查。")
    let schedule = custom("schedule", title: "统筹排序与交换比较", body: "核对目标与服务条件。")
    let arrange = custom("arrange", title: "排列组合与限制计数", body: "区分顺序与重复条件。")
    let fixtures: [(String, MathTeachingMethod)] = [
      ("物品任意分给几个人，总有一人至少得到若干件。", guarantee),
      ("每次先乘3再减12，连续两次后剩6，最初是多少？", inverse),
      ("同到的三人需要7、10、40分钟，只有一位理发师，怎样安排使三人所花时间总和最短？", schedule),
      ("从若干名男生中挑出几人站成一排，共有几种不同排法？", arrange)
    ]
    for (stem, expected) in fixtures {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: [unrelated, guarantee, inverse, schedule, arrange],
        requirements: "四年级，不用方程", textHint: stem)
      XCTAssertTrue(candidates.contains(expected), "\(stem): \(candidates.map(\.title))")
      XCTAssertFalse(candidates.contains(unrelated), "An exclusion in unrelated body prose must not acquire structural evidence")
    }
    for (stem, absent) in [("请等待回答完成", schedule),
                           ("同学们站成一排，求整队人数", arrange),
                           ("把19块巧克力平均分给3个人，余几块", guarantee)] {
      XCTAssertTrue(MathLocalSkillRetrieval.retrieve(methods: [absent],
        requirements: "四年级，不用方程", textHint: stem).isEmpty,
        "One generic word is not structural evidence: \(stem)")
    }
  }

  func testFocusedStructureDropsStoryNoiseButKeepsCombinedQuestions() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "focused", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    let request = "四年级，不用方程"
    let guaranteeStem = "31颗糖任意分给5个小朋友，请说明一定有一人至少拿到7颗。"
    let guarantee = MathLocalSkillRetrieval.retrieve(methods: methods,
      requirements: request, textHint: guaranteeStem)
    XCTAssertTrue(guarantee.contains { $0.title == "抽屉原则" })
    XCTAssertFalse(guarantee.contains { ["植树问题", "行程问题", "年龄问题"].contains($0.title) },
      "Story nouns in examples do not supply positive discovery evidence")
    let mixed = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request,
      textHint: guaranteeStem + "另一问：甲组4人平均80分，乙组2人平均92分，合组后平均几分？")
    XCTAssertTrue(mixed.contains { $0.title == "抽屉原则" }, mixed.map(\.title).joined(separator: "、"))
    XCTAssertTrue(mixed.contains { $0.title == "平均数问题" }, mixed.map(\.title).joined(separator: "、"))
    XCTAssertLessThanOrEqual(mixed.count, 7)
    let original = methods.first { $0.title == "还原问题" }!
    let edited = MathTeachingMethod(id: original.id, versionID: "user-edited", title: "用户独立方法",
      category: original.category, instructions: "用户改写后的新内容，未确认原还原方法的适用范围。",
      createdAt: original.createdAt,
      teachingPermissions: .init(minimumGrade: 4, equationRequirement: .notRequired, extensionRequirement: .none))
    let editedCandidates = MathLocalSkillRetrieval.retrieve(methods: methods.map { $0.id == edited.id ? edited : $0 },
      requirements: request, textHint: "原有一些糖，每次先乘3再送走12颗，连续两次最后剩6颗，起初有几颗？")
    XCTAssertFalse(editedCandidates.contains { $0.id == edited.id },
      "Edited project content must not inherit the former snapshot's discovery metadata")
  }

  func testSupplementDomainsRecallFromActualOCRWithoutGoldInQuery() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("docs/evaluations/2026-10-22-skill-expansion")
    let goldFile = root.appendingPathComponent("gold-new-transfer.json")
    guard FileManager.default.fileExists(atPath: goldFile.path) else { throw XCTSkip("Local transfer fixture not available") }
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: goldFile)) as? [String: Any])
    let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 14)
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "supplement-ocr", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for item in cases {
      let id = try XCTUnwrap(item["id"] as? String)
      let name = try XCTUnwrap(item["skill"] as? String)
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let data = try Data(contentsOf: root.appendingPathComponent("questions/" + id + ".png"))
      let hint = try await MathQuestionIndexer.recognize(data)
      let needsExtension = item["needsExtensionPermission"] as? Bool == true
      let request = "四年级，不用方程，请解释并验算。" + (needsExtension ? "允许拓展。" : "")
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: request, textHint: hint)
      print("SUPPLEMENT_OCR_RECALL \(id): EXPECTED=\(name) OCR=\(hint) CANDIDATES=\(candidates.map(\.title))")
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, "\(id): \(candidates.map(\.title))")
      XCTAssertLessThanOrEqual(candidates.count, 7)
      if needsExtension {
        let restricted = MathLocalSkillRetrieval.retrieve(methods: methods,
          requirements: "四年级，不用方程", textHint: hint)
        XCTAssertFalse(restricted.contains { $0.id == expected.sourceID }, "Photo content cannot grant extension permission")
      }
    }
  }

  func testGaussKnownSourceOCRRecallsCandidates() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("docs/evaluations/2026-10-21-gauss-grade4/questions")
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "known-source", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (id, expectedName) in [
      ("gauss-406-interest-q2", "pigeonhole-principle"),
      ("gauss-409-interest-q2", "reverse-operations"),
      ("gauss-412-interest-q2", "scheduling-and-exchange"),
      ("gauss-421-interest-q3", "counting-by-cases-and-stages")
    ] {
      let image = root.appendingPathComponent(id + ".png")
      guard FileManager.default.fileExists(atPath: image.path) else {
        throw XCTSkip("Local original source image not available")
      }
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == expectedName })
      let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: image))
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。", textHint: hint)
      print("GAUSS_RETRIEVAL_REGRESSION \(id): OCR=\(hint) CANDIDATES=\(candidates.map(\.title))")
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, id)
      XCTAssertLessThanOrEqual(candidates.count, 7)
      if id == "gauss-421-interest-q3" {
        let restricted = try XCTUnwrap(catalogue.skills.first { $0.name == "restricted-arrangements" })
        XCTAssertFalse(candidates.contains { $0.id == restricted.sourceID }, "OCR cannot grant extension permission")
        let withPermission = MathLocalSkillRetrieval.retrieve(methods: methods,
          requirements: "四年级，不用方程，允许使用拓展知识", textHint: hint)
        XCTAssertTrue(withPermission.contains { $0.id == restricted.sourceID }, "Explicitly allowed advanced candidate remains recallable")
      }
    }
  }

  func testOptionalOriginalSourceRetrievalDiagnostic() async throws {
    guard let imagePath = ProcessInfo.processInfo.environment["MATH_LOCAL_SOURCE_DIAGNOSTIC_IMAGE"] else {
      throw XCTSkip("Opt-in source OCR retrieval diagnostic")
    }
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map { skill in
      MathTeachingMethod(id: skill.sourceID, versionID: "project", title: skill.title,
        category: skill.category, instructions: skill.instructions, createdAt: Date())
    }
    let requirements = "不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。"
    let hint = try await MathQuestionIndexer.recognize(Data(contentsOf: URL(fileURLWithPath: imagePath)))
    let eligible = MathMethodMatcher.eligibleMethods(methods, question: requirements, catalogue: try MathTeachingReviewCatalogue.load())
    let shortlist = MathLocalSkillRetrieval.retrieve(methods: methods, requirements: requirements, textHint: hint)
    let documents: [[String: String]] = eligible.map { method in
      ["id": method.id, "title": method.title, "category": method.category,
        "body": method.instructions + "\n" + (catalogue.discoveryMetadata(for: method)?.description ?? "")]
    }
    let diagnostics: [String: Any] = ["requirements": requirements, "hint": hint, "documents": documents]
    try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: imagePath + ".retrieval-diagnostic.json"))
    print("SOURCE_RETRIEVAL_HINT: " + hint)
    print("SOURCE_RETRIEVAL_ELIGIBLE: " + eligible.map(\.title).joined(separator: " | "))
    print("SOURCE_RETRIEVAL_SHORTLIST: " + shortlist.map(\.title).joined(separator: " | "))
    XCTAssertFalse(hint.isEmpty)
  }

  func testRoundedQuotientSourceAndTransferRecallRespectPermission() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "rounded-quotient-iteration" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "rounded-recall", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for stem in [
      "甲袋中有194919481947…321个球，乙袋为空，每次向甲袋加不多于9个球，使球数为10的倍数，再把其中十分之九移到乙袋，最少多少次甲袋只有1个球？",
      "把25到1降序拼接，每次补最少数量成为10的倍数再取十分之一，最少几次到1？",
      "正整数28反复向上取整除以3，最少几次降至1？"
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程，允许使用拓展知识", textHint: stem)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, candidates.map(\.title).joined(separator: "、"))
      XCTAssertLessThanOrEqual(candidates.count, 7)
      let restricted = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem + "允许使用拓展知识")
      XCTAssertFalse(restricted.contains { $0.id == expected.sourceID }, "OCR cannot grant extension permission")
    }
  }

  func testUnequalGivenGroupSumsRecallWithoutForcingEqualSums() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "unequal-group-sums-and-alternating-elimination" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "unequal-groups", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for stem in [
      "七个连续自然数填在环上，相邻两数之和依次12、9、6、10、7、4、8，星号内填几？",
      "将1到7各一次填在三条射线中，中心共有，三条线上三个数之和分别8、11、15，圆周三个外端的乘积最大多少？",
      "五个点围成环，相邻两数和顺时针9、11、13、10、7，求起点。"
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, candidates.map(\.title).joined(separator: "、"))
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testActualDifferenceLabelStemsRecallWithoutInventingDistinctness() throws {
    let catalogue = try MathSkillCatalogue.load()
    let expected = try XCTUnwrap(catalogue.skills.first { $0.name == "difference-constrained-labels-and-signed-cycles" })
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "difference-recall", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for stem in [
      "把1到8分别填在8个圆内，使任意两个由线段直接相连的圆内的数字之差都不等于1。",
      "在图示8个圆内填1到8，使每条线段连结的两个圆内所填数之差（大减小）恰好是1、2、3、4、5、6、7。",
      "七个圆围成环，填一些自然数，最小的一个数是1，相邻两个圆内的数之差（大数减小数）等于两圆间标出的数1、2、3、4、5、6、7。"
    ] {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, candidates.map(\.title).joined(separator: "、"))
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

  func testActualTowerRelationsRecallTheirDistinctOperation() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "tower-recall", title: $0.title,
        category: $0.category, instructions: $0.instructions, createdAt: Date())
    }
    for (name, stem) in [
      ("additive-towers-and-network-propagation", "6个圆内分别填不同自然数，每个数都是与它相连的上面两个数之和，最下面那个数最小是几？"),
      ("absolute-difference-tower-propagation", "1至10各一次填图中四层数塔，每个下圈是相连上面两个数之差（大减小），第二排中心9已给，补齐。"),
      ("additive-towers-and-network-propagation", "13个圆恰用1至13，3和4已给，上面两个圈内数的和等于相连的下面圈内数，最下四圈和43，补全。")
    ] {
      let expected = try XCTUnwrap(catalogue.skills.first { $0.name == name })
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: "四年级，不用方程", textHint: stem)
      XCTAssertTrue(candidates.contains { $0.id == expected.sourceID }, candidates.map(\.title).joined(separator: "、"))
      XCTAssertLessThanOrEqual(candidates.count, 7)
    }
  }

}
