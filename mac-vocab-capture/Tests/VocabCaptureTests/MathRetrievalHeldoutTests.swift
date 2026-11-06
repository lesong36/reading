import Foundation
import XCTest
@testable import VocabCapture

/// Fresh requests drafted from the shipped skill descriptions, before reading
/// existing retrieval tests or evaluation corpora. These assert candidate recall,
/// never final method adoption, ordering, or an exact positive candidate list.
final class MathRetrievalHeldoutTests: XCTestCase {
  private struct Request {
    let name: String
    let requirements: String
    let textHint: String
    let expectedAny: Set<String>
  }

  func testFreshElementaryRequestsRecallPlausibleCandidates() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "heldout-" + $0.name,
        title: $0.title, category: $0.category, instructions: $0.instructions,
        createdAt: Date(timeIntervalSince1970: 0))
    }
    let requests: [Request] = [
      .init(name: "two tubs of beads", requirements: "四年级，不用方程，讲清楚怎么算。",
        textHint: "两盒串珠合计86颗，紫盒比橙盒多18颗。两盒各装了几颗？",
        expectedAny: ["sum-and-difference"]),
      .init(name: "colloquial total and multiple", requirements: "给四年级讲，别列字母方程。",
        textHint: "这两卷彩带一共72米，长的那卷是短的3倍，短的到底有几米呀？",
        expectedAny: ["sum-and-ratio"]),
      .init(name: "difference and multiple with changed objects", requirements: "四年级，不用方程。",
        textHint: "甲仓库的折叠凳是乙仓库的4倍，甲比乙多63把，乙仓库有几把？",
        expectedAny: ["difference-and-ratio"]),
      .init(name: "posts rather than trees", requirements: "四年级，请把两头也算清楚。",
        textHint: "一条长96米的直道每隔8米立一根标杆，两端都立，要准备几根标杆？",
        expectedAny: ["intervals-and-endpoints"]),
      .init(name: "stock arriving and leaving", requirements: "四年级，不用方程，按先后顺序说。",
        textHint: "器材室原有95个毽子，上午借走28个，下午新送来16个，现在有几只毽子？",
        expectedAny: ["accumulation-and-inventory", "inventory-transitions-diagram"]),
      .init(name: "repeating sticker pattern", requirements: "四年级，帮我找规律。",
        textHint: "贴纸按月亮、星星、星星、太阳的次序一遍遍贴，第38张是什么图案？",
        expectedAny: ["periodic-patterns", "period-diagram"]),
      .init(name: "workers with explicit extension permission", requirements: "小学四年级，可以使用拓展知识，但不用方程。",
        textHint: "整理同一批图书，甲独自要6小时，乙独自要12小时，两人一起整理几小时能完成？",
        expectedAny: ["work-rate"]),
      .init(name: "question entirely in requirements", requirements: "四年级，不用方程。小航把原有贴纸先送掉一半，再送掉7张，最后剩15张，原先有几张？请从最后一步往前想。",
        textHint: "", expectedAny: ["reverse-operations", "state-transitions-diagram"]),
    ]
    for request in requests {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: request.requirements, textHint: request.textHint)
      let names = Set(candidates.compactMap { catalogue.discoveryMetadata(for: $0)?.name })
      let eligible = MathMethodMatcher.eligibleMethods(methods, question: request.requirements)
      let eligibleNames = Set(eligible.compactMap { catalogue.discoveryMetadata(for: $0)?.name })
      XCTAssertFalse(eligibleNames.intersection(request.expectedAny).isEmpty,
        "Fixture permission error for \(request.name): expected candidate must be eligible")
      XCTAssertFalse(names.intersection(request.expectedAny).isEmpty,
        "Held-out recall miss for \(request.name). Expected one of \(request.expectedAny.sorted()); got \(names.sorted())")
      XCTAssertTrue(Set(candidates.map(\.id)).isSubset(of: Set(eligible.map(\.id))),
        "Retrieval must preserve user teaching permissions: \(request.name)")
    }
  }

  func testFreshRequestsWithoutMathEvidenceDoNotInventCandidates() throws {
    let catalogue = try MathSkillCatalogue.load()
    let methods = catalogue.skills.map {
      MathTeachingMethod(id: $0.sourceID, versionID: "heldout-" + $0.name,
        title: $0.title, category: $0.category, instructions: $0.instructions,
        createdAt: Date(timeIntervalSince1970: 0))
    }
    let requests: [(String, String, String)] = [
      ("generic teaching instruction", "请使用小学生的知识领域解题，请验算确定答案的正确性。", ""),
      ("numeric OCR only", "四年级，不要使用方程。", "17 24 86 309\n4 8 16 32"),
      ("English explanation", "请解释这句英语，告诉我为什么要用过去完成时。", "She had packed her suitcase before the taxi arrived."),
      ("illustration request", "帮我画一只戴着围巾的小狐狸，在雨里撑着透明伞，水彩风格。", ""),
    ]
    for (name, requirements, textHint) in requests {
      let candidates = MathLocalSkillRetrieval.retrieve(methods: methods,
        requirements: requirements, textHint: textHint)
      XCTAssertTrue(candidates.isEmpty,
        "Held-out nonmath/no-evidence request \(name) retrieved \(candidates.map(\.title))")
    }
  }
}
