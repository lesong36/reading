import Foundation

struct MathTagDefinition: Sendable {
  let assignment: MathQuestionTag
  let definition: String
  let boundary: String
  let group: String
}

struct MathTagCatalogue: Sendable {
  let tags: [MathTagDefinition]

  private struct Source: Decodable {
    let catalogueID: String
    let version: String
    let tags: [Entry]
    let curriculumNodes: [Node]
    private enum CodingKeys: String, CodingKey {
      case catalogueID = "catalogue_id"
      case version, tags
      case curriculumNodes = "curriculum_nodes"
    }
  }
  private struct Entry: Decodable {
    let id: String
    let axis: String
    let label: String
    let definition: String
    let exclusion: String
    let parentID: String?
    private enum CodingKeys: String, CodingKey {
      case id, axis, label, definition, exclusion
      case parentID = "parent_id"
    }
  }
  private struct Node: Decodable {
    let id: String
    let label: String
  }

  init(data: Data) throws {
    let source = try JSONDecoder().decode(Source.self, from: data)
    let groups = Dictionary(uniqueKeysWithValues: source.curriculumNodes.map { ($0.id, $0.label) })
    let axes = ["question_form", "curriculum_knowledge", "problem_family"]
    tags =
      source.tags.filter { axes.contains($0.axis) }.map { entry in
        MathTagDefinition(
          assignment: MathQuestionTag(
            axis: entry.axis, tagID: entry.id,
            catalogueVersion: source.catalogueID + "@" + source.version, label: entry.label),
          definition: entry.definition, boundary: entry.exclusion,
          group: entry.parentID.flatMap { groups[$0] } ?? "")
      } + [
        MathTagDefinition(
          assignment: MathQuestionTag(
            axis: "problem_family", tagID: "pf.digit_composition",
            catalogueVersion: "product-math-extensions@0.1.0", label: "数字组数"),
          definition: "按给定数字及次数限制组成整数或算式。", boundary: "属于应用扩展题型，不是独立课标知识点。", group: "扩展题型"),
        MathTagDefinition(
          assignment: MathQuestionTag(
            axis: "problem_family", tagID: "pf.product_extrema",
            catalogueVersion: "product-math-extensions@0.1.0", label: "乘积极值"),
          definition: "在明确的数字或组数限制下求乘积最大或最小。", boundary: "仅出现乘法计算不标此项；属于应用扩展题型。", group: "扩展题型"),
      ]
  }

  static func load() throws -> MathTagCatalogue {
    // Installed apps keep the catalogue in their resources, independent of the source checkout.
    var url = Bundle.main.url(forResource: "PrimaryMathTags", withExtension: "json")
    #if SWIFT_PACKAGE
      if url == nil {
        url = Bundle.module.url(forResource: "PrimaryMathTags", withExtension: "json")
      }
    #endif
    guard let url else { throw MathQuestionStoreError.database("标签目录缺失，请重新安装应用") }
    return try MathTagCatalogue(data: Data(contentsOf: url))
  }
}

extension MathQuestionTag {
  var statusSuffix: String {
    switch status {
    case "suggested": return origin == "ai" ? "（AI 自动）" : "（待确认）"
    case "rejected": return "（已拒绝）"
    default: return ""
    }
  }
  var axisTitle: String {
    switch axis {
    case "question_form": return "形式"
    case "curriculum_knowledge": return "知识点"
    case "problem_family": return "题型"
    default: return "自定义"
    }
  }
}
