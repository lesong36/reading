import AppKit
import CoreText

/// Uses one vector layout for both screen PNGs and PDF CGContext rendering.
/// draw(in:rect:) accepts a conventional y-up CGContext and flips inside the supplied rect.
enum MathDiagramRenderer {
  static let rendererVersion = 3
  struct Element {
    enum Shape { case text(String, CGFloat, Bool), box(CGColor, Bool), line(CGPoint), point, ellipse(CGColor), arrow(CGPoint) }
    var frame: CGRect
    var shape: Shape
  }
  struct Layout {
    var size: CGSize
    var elements: [Element]
  }
  private static let ink = CGColor(gray: 0.17, alpha: 1)
  private static let blue = CGColor(red: 0.18, green: 0.42, blue: 0.69, alpha: 1)
  private static let lightBlue = CGColor(red: 0.88, green: 0.94, blue: 0.99, alpha: 1)
  private static let lightGold = CGColor(red: 1, green: 0.96, blue: 0.84, alpha: 1)
  private static let rule = CGColor(gray: 0.75, alpha: 1)

  static func size(_ diagram: MathDiagram, width: CGFloat = 900) throws -> CGSize {
    try layout(diagram, width: width).size
  }

  @MainActor static func image(_ diagram: MathDiagram, width: CGFloat = 900) throws -> NSImage {
    let data = try renderPNG(diagram, width: width)
    guard let image = NSImage(data: data) else { throw MathDiagram.ValidationError(message: "无法读取图解图片。") }
    image.size = try size(diagram, width: width)
    return image
  }

  static func renderPNG(_ diagram: MathDiagram, width: CGFloat = 900, scale: CGFloat = 2) throws -> Data {
    guard scale.isFinite && (1...3).contains(scale) else { throw MathDiagram.ValidationError(message: "图解缩放比例无效。") }
    let layout = try layout(diagram, width: width)
    let pixelWidth = Int(ceil(layout.size.width * scale)), pixelHeight = Int(ceil(layout.size.height * scale))
    guard pixelWidth * pixelHeight <= 32_000_000,
      let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw MathDiagram.ValidationError(message: "图解尺寸超出支持范围。") }
    context.scaleBy(x: scale, y: scale)
    render(layout, in: context, rect: CGRect(origin: .zero, size: layout.size))
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw MathDiagram.ValidationError(message: "图解图片生成失败。") }
    return png
  }

  static func draw(_ diagram: MathDiagram, in context: CGContext, rect: CGRect, layoutWidth: CGFloat = 900) throws {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { throw MathDiagram.ValidationError(message: "图解绘制区域无效。") }
    let diagramLayout = try layout(diagram, width: layoutWidth)
    render(diagramLayout, in: context, rect: rect)
  }

  static func layout(_ diagram: MathDiagram, width: CGFloat = 900) throws -> Layout {
    try diagram.validate()
    guard width.isFinite && (360...1600).contains(width) else { throw MathDiagram.ValidationError(message: "图解宽度需要在 360 至 1600 之间。") }
    let margin: CGFloat = 24, contentWidth = width - 2 * margin
    var y: CGFloat = margin
    var elements: [Element] = []
    func text(_ value: String, x: CGFloat = 24, w: CGFloat? = nil, size: CGFloat = 16, bold: Bool = false) -> CGFloat {
      let w = w ?? contentWidth
      let h = textHeight(value, width: w, size: size, bold: bold)
      elements.append(.init(frame: CGRect(x: x, y: y, width: w, height: h), shape: .text(value, size, bold)))
      return h
    }
    y += text(diagram.title, size: 21, bold: true) + 16
    let facts = Dictionary(uniqueKeysWithValues: diagram.facts.map { ($0.id, $0) })
    func display(_ fact: MathDiagram.Fact) -> String {
      let origin = fact.origin == .given ? "题目" : fact.origin == .derived ? "推得"
        : fact.origin == .constant ? "运算常数" : "待求"
      return "\(origin) · \(fact.value.map(number) ?? "？")\(fact.unit)"
    }
    func line(_ start: CGPoint, _ end: CGPoint, arrow: Bool = false) {
      elements.append(.init(frame: CGRect(x: start.x, y: start.y, width: max(0, end.x - start.x), height: max(0, end.y - start.y)), shape: arrow ? .arrow(end) : .line(end)))
    }
    func label(_ value: String, frame: CGRect, size: CGFloat = 14, bold: Bool = true) {
      elements.append(.init(frame: frame, shape: .text(value, size, bold)))
    }
    let segmentColors = [lightBlue, lightGold, CGColor(red: 0.88, green: 0.96, blue: 0.89, alpha: 1)]
    switch diagram.kind {
    case .barComparison, .equalParts:
      let maximum = diagram.factIDs.compactMap { facts[$0]?.value }.max() ?? 1
      let maxParts = CGFloat(diagram.parts.max() ?? 1)
      for (index, id) in diagram.factIDs.enumerated() {
        let fact = facts[id]!
        y += text("\(fact.label)   \(display(fact))", bold: true) + 8
        let length: CGFloat
        if diagram.kind == .equalParts { length = contentWidth * CGFloat(diagram.parts[index]) / maxParts }
        else if let value = fact.value { length = maximum > 0 ? contentWidth * CGFloat(value / maximum) : 0 }
        else { length = contentWidth * 0.62 }
        // A checked three-row comparison places the difference after the smaller bar,
        // making the extra equal parts line up with the larger bar's remaining portion.
        let isExtraParts = diagram.kind == .equalParts && index == 2 && diagram.factIDs.count == 3
          && diagram.parts[2] == diagram.parts[1] - diagram.parts[0]
          && diagram.relations.contains { $0.operation == .difference
            && $0.inputIDs == [diagram.factIDs[1], diagram.factIDs[0]] && $0.outputID == id }
        let offset = isExtraParts ? contentWidth * CGFloat(diagram.parts[0]) / maxParts : 0
        let frame = CGRect(x: margin + offset, y: y, width: max(length, 1), height: 30)
        elements.append(.init(frame: frame, shape: .box(fact.origin == .derived ? lightGold : lightBlue, fact.origin == .unknown)))
        if diagram.kind == .equalParts {
          for division in 1..<diagram.parts[index] {
            let x = frame.minX + length * CGFloat(division) / CGFloat(diagram.parts[index])
            elements.append(.init(frame: CGRect(x: x, y: y, width: 0, height: 30), shape: .line(CGPoint(x: x, y: y + 30))))
          }
        }
        y += 45
      }
      let hasUnknown = diagram.factIDs.contains(where: { facts[$0]?.origin == .unknown })
      let hint = diagram.kind == .equalParts ? "每格表示相同的一份。" + (hasUnknown ? "未知量保持未知。" : "") : hasUnknown ? "虚线表示未知量：仅作示意，不按数值比例绘制。" : "线段长度按以上数量的比例绘制。"
      y += text(hint, size: 13) + 14
    case .state:
      for (index, id) in diagram.factIDs.enumerated() {
        let fact = facts[id]!
        let label = "\(index + 1). \(fact.label)\n\(display(fact))"
        let h = textHeight(label, width: contentWidth - 24, size: 16, bold: true) + 22
        elements.append(.init(frame: CGRect(x: margin, y: y, width: contentWidth, height: h), shape: .box(fact.origin == .derived ? lightGold : lightBlue, fact.origin == .unknown)))
        elements.append(.init(frame: CGRect(x: margin + 12, y: y + 11, width: contentWidth - 24, height: h - 22), shape: .text(label, 16, true)))
        y += h + 10
        if index + 1 < diagram.factIDs.count {
          let nextID = diagram.factIDs[index + 1]
          let relation = diagram.relations.first { $0.outputID == nextID && $0.inputIDs.contains(id) }!
          y += text("↓  " + relationText(relation, facts: facts), size: 14) + 12
        }
      }
    case .table:
      let columnWidth = contentWidth / CGFloat(diagram.columns.count + 1)
      let headers = ["比较项目"] + diagram.columns
      let headerHeight = headers.map { textHeight($0, width: columnWidth - 16, size: 15, bold: true) }.max()! + 20
      for (index, header) in headers.enumerated() {
        let x = margin + CGFloat(index) * columnWidth
        elements.append(.init(frame: CGRect(x: x, y: y, width: columnWidth, height: headerHeight), shape: .box(lightBlue, false)))
        elements.append(.init(frame: CGRect(x: x + 8, y: y + 10, width: columnWidth - 16, height: headerHeight - 20), shape: .text(header, 15, true)))
      }
      y += headerHeight
      for row in diagram.rows {
        let labels = [row.label] + row.factIDs.map { display(facts[$0]!) }
        let height = labels.map { textHeight($0, width: columnWidth - 16, size: 15, bold: false) }.max()! + 20
        for (index, label) in labels.enumerated() {
          let x = margin + CGFloat(index) * columnWidth
          let color = index > 0 && facts[row.factIDs[index - 1]]?.origin == .derived ? lightGold : CGColor(gray: 1, alpha: 1)
          elements.append(.init(frame: CGRect(x: x, y: y, width: columnWidth, height: height), shape: .box(color, false)))
          elements.append(.init(frame: CGRect(x: x + 8, y: y + 10, width: columnWidth - 16, height: height - 20), shape: .text(label, 15, false)))
        }
        y += height
      }
      y += 18
    case .area:
      let a = facts[diagram.factIDs[0]]!, b = facts[diagram.factIDs[1]]!, area = facts[diagram.factIDs[2]]!
      y += text("\(a.label)：\(display(a))；\(b.label)：\(display(b))", bold: true) + 14
      var plotWidth = contentWidth
      let areaCaption = "\(area.label)\n\(display(area))"
      let captionHeight = diagram.parts.isEmpty ? textHeight(areaCaption, width: plotWidth - 32, size: 18, bold: true) + 32 : 0
      var plotHeight = max(captionHeight, min(320, max(150, plotWidth * CGFloat(b.value! / a.value!))))
      let lengthUnits: Set<String> = ["厘米", "米", "千米", "cm", "m", "km"]
      var proportional = false
      if a.unit == b.unit, lengthUnits.contains(a.unit) {
        let ratio = CGFloat(b.value! / a.value!)
        let candidateWidth = min(contentWidth, 320 / ratio)
        let candidateHeight = candidateWidth * ratio
        let requiredCaption = diagram.parts.isEmpty
          ? textHeight(areaCaption, width: max(1, candidateWidth - 32), size: 18, bold: true) + 32 : 0
        if candidateWidth >= 200, candidateHeight >= max(150, requiredCaption) {
          plotWidth = candidateWidth
          plotHeight = candidateHeight
          proportional = true
        }
      }
      let rect = CGRect(x: margin, y: y, width: plotWidth, height: plotHeight)
      elements.append(.init(frame: rect, shape: .box(lightBlue, false)))
      if diagram.parts.count == 2 {
        let splitX = CGFloat(Double(diagram.parts[0]) / a.value!) * plotWidth
        let splitY = CGFloat(Double(diagram.parts[1]) / b.value!) * plotHeight
        elements.append(.init(frame: CGRect(x: margin + splitX, y: y, width: 0, height: plotHeight), shape: .line(CGPoint(x: margin + splitX, y: y + plotHeight))))
        elements.append(.init(frame: CGRect(x: margin, y: y + splitY, width: plotWidth, height: 0), shape: .line(CGPoint(x: margin + plotWidth, y: y + splitY))))
        let widths = [Double(diagram.parts[0]), a.value! - Double(diagram.parts[0])]
        let heights = [Double(diagram.parts[1]), b.value! - Double(diagram.parts[1])]
        let xs: [CGFloat] = [0, splitX], ys: [CGFloat] = [0, splitY], ws = [splitX, plotWidth - splitX], hs = [splitY, plotHeight - splitY]
        for row in 0...1 { for column in 0...1 {
          let cell = CGRect(x: margin + xs[column] + 6, y: y + ys[row] + 6, width: ws[column] - 12, height: hs[row] - 12)
          let value = "\(number(widths[column])) × \(number(heights[row]))\n= \(number(widths[column] * heights[row]))\(area.unit)"
          guard cell.width >= 55, cell.height >= textHeight(value, width: cell.width, size: 13, bold: true) else { throw MathDiagram.ValidationError(message: "面积分块过窄，无法清楚显示标注。") }
          elements.append(.init(frame: cell, shape: .text(value, 13, true)))
        } }
      } else {
        let label = "\(area.label)\n\(display(area))"
        elements.append(.init(frame: CGRect(x: margin + 16, y: y + 16, width: plotWidth - 32, height: plotHeight - 32), shape: .text(label, 18, true)))
      }
      y += plotHeight + 12
      y += text(proportional ? "矩形按边长比例绘制；数量与单位按标注计算。"
        : "矩形表示乘积关系，仅作示意、不按边长比例绘制；数量与单位按标注计算。", size: 13) + 14
    case .interval:
      let start = facts[diagram.factIDs[0]]!, end = facts[diagram.factIDs[1]]!
      let count = facts[diagram.factIDs[2]]!, per = facts[diagram.factIDs[3]]!, total = facts[diagram.factIDs[4]]!
      let gaps = Int(count.value!)
      let endpointWidth = (contentWidth - 16) / 2
      let endpointLabels = ["\(start.label)：\(number(start.value!))", "\(end.label)：\(number(end.value!))"]
      let endpointHeight = endpointLabels.map { textHeight($0, width: endpointWidth, size: 16, bold: true) }.max()!
      for (index, label) in endpointLabels.enumerated() {
        elements.append(.init(frame: CGRect(x: margin + CGFloat(index) * (endpointWidth + 16), y: y, width: endpointWidth, height: endpointHeight), shape: .text(label, 16, true)))
      }
      y += endpointHeight + 25
      let left = margin + 6, span = contentWidth - 12
      let condensed = CGFloat(gaps) * 48 > span
      let positionCount = condensed ? 6 : gaps + 1
      // A condensed drawing keeps two actual gaps at each end and leaves a visibly empty middle.
      let slots = condensed ? [0, 1, 2, 4, 5, 6] : Array(0..<positionCount)
      let slotCount = condensed ? 6 : gaps
      for index in 0..<(positionCount - 1) {
        if condensed && index == 2 { continue }
        let x = left + span * CGFloat(slots[index]) / CGFloat(slotCount)
        let next = left + span * CGFloat(slots[index + 1]) / CGFloat(slotCount)
        elements.append(.init(frame: CGRect(x: x, y: y, width: next - x, height: 0), shape: .line(CGPoint(x: next, y: y))))
      }
      for slot in slots {
        let x = left + span * CGFloat(slot) / CGFloat(slotCount)
        elements.append(.init(frame: CGRect(x: x - 5, y: y - 5, width: 10, height: 10), shape: .point))
      }
      if condensed {
        let ellipsisWidth = span / 3 - 12
        elements.append(.init(frame: CGRect(x: left + span / 3 + 6, y: y - 14, width: ellipsisWidth, height: textHeight("⋯", width: ellipsisWidth, size: 24, bold: true)), shape: .text("⋯", 24, true)))
      }
      y += 28
      // The bracket spans the whole path, including any explicitly omitted middle gaps.
      elements.append(.init(frame: CGRect(x: left, y: y - 8, width: 0, height: 8), shape: .line(CGPoint(x: left, y: y))))
      elements.append(.init(frame: CGRect(x: left, y: y, width: span, height: 0), shape: .line(CGPoint(x: left + span, y: y))))
      elements.append(.init(frame: CGRect(x: left + span, y: y - 8, width: 0, height: 8), shape: .line(CGPoint(x: left + span, y: y))))
      y += 12
      y += text("共 \(number(count.value!)) 个间隔", size: 18, bold: true) + 10
      y += text(condensed ? "点表示位置，线段表示间隔；中间省略 \(gaps - 4) 个间隔。" : "点表示位置，线段表示间隔；图中完整画出 \(gaps) 个间隔。", size: 13) + 14
      y += text("\(per.label)：\(display(per))", bold: true) + 8
      y += text("\(total.label)：\(display(total))", size: 18, bold: true) + 14
    case .partWhole:
      let whole = facts[diagram.factIDs[0]]!
      let portions = diagram.factIDs.dropFirst().map { facts[$0]! }
      let proportional = portions.allSatisfy { $0.value != nil } && (whole.value ?? 0) > 0
      // Labels remain outside the proportional segments, including very small portions.
      for (index, fact) in portions.enumerated() {
        y += text("\(index + 1). \(fact.label)：\(display(fact))", size: 15) + 5
      }
      y += 9
      var x = margin
      for (index, fact) in portions.enumerated() {
        let length = proportional ? contentWidth * CGFloat(fact.value! / whole.value!) : contentWidth / CGFloat(portions.count)
        let frame = CGRect(x: x, y: y, width: length, height: 40)
        elements.append(.init(frame: frame, shape: .box(segmentColors[index % segmentColors.count], fact.origin == .unknown)))
        if length >= 24 {
          let value = "\(index + 1)", h = textHeight("\(index + 1)", width: length - 16, size: 14, bold: true)
          label(value, frame: CGRect(x: frame.minX + 8, y: frame.minY + (40 - h) / 2, width: length - 16, height: h))
        }
        x += length
      }
      y += 53
      line(.init(x: margin, y: y - 7), .init(x: margin, y: y))
      line(.init(x: margin, y: y), .init(x: margin + contentWidth, y: y))
      line(.init(x: margin + contentWidth, y: y - 7), .init(x: margin + contentWidth, y: y))
      y += 10
      y += text("\(whole.label)：\(display(whole))", size: 18, bold: true) + 8
      y += text(proportional ? "各部分首尾相接组成整体；长度按数量比例绘制。" : "各部分首尾相接组成整体；仅作等宽示意，不按数值比例绘制。", size: 13) + 14
    case .venn:
      let regions = diagram.factIDs.prefix(3).map { facts[$0]! }
      for (index, fact) in regions.enumerated() {
        y += text("\(index + 1). \(fact.label)：\(display(fact))", size: 15) + 4
      }
      y += 12
      let diameter = min(contentWidth * 0.64, 250)
      let overlapSpan = diameter * 1.56
      let left = margin + (contentWidth - overlapSpan) / 2
      let plotY = y
      elements.append(.init(frame: CGRect(x: left, y: y, width: diameter, height: diameter), shape: .ellipse(CGColor(red: 0.23, green: 0.53, blue: 0.85, alpha: 0.18))))
      elements.append(.init(frame: CGRect(x: left + diameter * 0.56, y: y, width: diameter, height: diameter), shape: .ellipse(CGColor(red: 0.93, green: 0.63, blue: 0.18, alpha: 0.18))))
      let regionWidth = diameter * 0.28
      for (index, fact) in regions.enumerated() {
        let centers: [CGFloat] = [0.29, 0.78, 1.27]
        let value = "\(index + 1)\n\(number(fact.value!))\(fact.unit)"
        let h = textHeight(value, width: regionWidth, size: 14, bold: true)
        guard h <= diameter * 0.5 else { throw MathDiagram.ValidationError(message: "韦恩图区域数字过长，无法清楚显示。") }
        label(value, frame: CGRect(x: left + diameter * centers[index] - regionWidth / 2, y: plotY + (diameter - h) / 2, width: regionWidth, height: h))
      }
      y += diameter + 12
      let union = facts[diagram.factIDs[3]]!
      y += text("\(union.label)：\(display(union))", size: 17, bold: true) + 7
      if diagram.factIDs.count == 6 {
        let outside = facts[diagram.factIDs[4]]!, total = facts[diagram.factIDs[5]]!
        y += text("圈外 · \(outside.label)：\(display(outside))", size: 15) + 5
        y += text("\(total.label)：\(display(total))", size: 17, bold: true) + 7
      }
      y += text("交叠处只计一次；圆的大小为集合示意，不表示数量比例。", size: 13) + 14
    case .balance:
      let high = facts[diagram.factIDs[0]]!, low = facts[diagram.factIDs[1]]!
      let mean = facts[diagram.factIDs[2]]!, transfer = facts[diagram.factIDs[3]]!
      y += text("\(mean.label)：\(display(mean))", size: 16, bold: true) + 5
      y += text("\(transfer.label)：\(display(transfer))", size: 15) + 15
      let plotHeight: CGFloat = 180
      let barWidth = min(100, contentWidth * 0.25)
      let centers = [margin + contentWidth * 0.25, margin + contentWidth * 0.75]
      let baseline = y + plotHeight
      let maximum = max(high.value!, 1)
      let meanY = baseline - plotHeight * CGFloat(mean.value! / maximum)
      for (index, fact) in [high, low].enumerated() {
        let height = plotHeight * CGFloat(fact.value! / maximum)
        elements.append(.init(frame: CGRect(x: centers[index] - barWidth / 2, y: baseline - height, width: barWidth, height: height), shape: .box(index == 0 ? lightBlue : lightGold, false)))
      }
      // The common horizontal level is the average, not a third unrelated bar.
      line(.init(x: margin, y: meanY), .init(x: margin + contentWidth, y: meanY))
      let arrowY = y - 7
      line(.init(x: centers[0], y: arrowY), .init(x: centers[1], y: arrowY), arrow: true)
      y = baseline + 10
      let labelWidth = (contentWidth - 16) / 2
      let captions = [high, low].map { "\($0.label)\n\(display($0))" }
      let captionHeight = captions.map { textHeight($0, width: labelWidth, size: 15, bold: true) }.max()!
      for (index, caption) in captions.enumerated() {
        label(caption, frame: CGRect(x: margin + CGFloat(index) * (labelWidth + 16), y: y, width: labelWidth, height: captionHeight), size: 15)
      }
      y += captionHeight + 10
      y += text("横线表示平均量；箭头表示从较多的一边移给较少的一边，移量为差的一半。", size: 13) + 14
    case .cycle:
      let total = facts[diagram.factIDs[0]]!, period = facts[diagram.factIDs[1]]!
      let cycles = Int(facts[diagram.factIDs[2]]!.value!), remainder = Int(facts[diagram.factIDs[3]]!.value!)
      y += text("\(total.label)：\(display(total))；每周期 \(number(period.value!)) 项", size: 16, bold: true) + 12
      let count = diagram.columns.count
      let cellWidth = contentWidth / CGFloat(count)
      // Numbers in fixed-width cells identify the ordered names printed below.
      let numbered = diagram.columns.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "　")
      y += text(numbered, size: 14) + 10
      func cycleRow(_ caption: String, count itemCount: Int) {
        y += text(caption, size: 14, bold: true) + 5
        for index in 0..<itemCount {
          let frame = CGRect(x: margin + CGFloat(index) * cellWidth, y: y, width: cellWidth, height: 32)
          elements.append(.init(frame: frame, shape: .box(cycleColor(diagram.columns[index], index: index), false)))
          let h = textHeight("\(index + 1)", width: cellWidth - 8, size: 13, bold: true)
          label("\(index + 1)", frame: CGRect(x: frame.minX + 4, y: frame.minY + (32 - h) / 2, width: cellWidth - 8, height: h), size: 13)
        }
        y += 42
      }
      for cycle in 0..<min(cycles, 3) { cycleRow("第 \(cycle + 1) 个完整周期", count: count) }
      if cycles > 3 { y += text("⋯ 中间省略 \(cycles - 3) 个完整周期（每周期仍为 \(count) 项）", size: 13) + 10 }
      if remainder > 0 { cycleRow("最后 \(remainder) 个余项（从周期首项开始）", count: remainder) }
      else { y += text("恰好 \(cycles) 个完整周期，没有余项。", size: 14) + 10 }
      y += text("同一编号表示同一周期项；方格等宽表示顺序位置。", size: 13) + 14
    }
    y += text("数量关系", size: 15, bold: true) + 6
    // A table already displays its intermediate values. Repeat only relations
    // for displayed results and terminal conclusions, rather than printing the
    // whole computation tree below it. Validation still checks every relation.
    var shownOutputs = Set<String>()
    let displayed = Set(diagram.rows.flatMap(\.factIDs))
    let usedAsInput = Set(diagram.relations.flatMap(\.inputIDs))
    let visibleRelations = diagram.kind == .table ? diagram.relations.filter {
      (displayed.contains($0.outputID) || !usedAsInput.contains($0.outputID))
        && shownOutputs.insert($0.outputID).inserted
    } : diagram.relations
    for relation in visibleRelations { y += text(relationText(relation, facts: facts), size: 14) + 5 }
    y += 8
    y += text("图中关系已检查内部一致性；原题理解与答案仍需核验。", size: 12) + margin
    guard y <= 8000 else { throw MathDiagram.ValidationError(message: "图解内容过长，请拆分图形。") }
    for element in elements {
      if case .text(let value, let fontSize, let bold) = element.shape {
        guard textHeight(value, width: element.frame.width, size: fontSize, bold: bold) <= element.frame.height + 0.1 else {
          throw MathDiagram.ValidationError(message: "图解文字标注无法完整显示。")
        }
      }
    }
    let size = CGSize(width: width, height: ceil(y))
    guard elements.allSatisfy({ $0.frame.minX >= 0 && $0.frame.minY >= 0 && $0.frame.maxX <= size.width + 0.01 && $0.frame.maxY <= size.height + 0.01 && $0.frame.width >= 0 && $0.frame.height >= 0 }) else { throw MathDiagram.ValidationError(message: "图解标注超出绘制区域。") }
    return .init(size: size, elements: elements)
  }

  private static func cycleColor(_ name: String, index: Int) -> CGColor {
    let colors: [(String, CGFloat, CGFloat, CGFloat)] = [
      ("红", 0.98, 0.78, 0.77), ("黄", 1, 0.94, 0.62), ("蓝", 0.76, 0.88, 0.99),
      ("绿", 0.75, 0.93, 0.78), ("紫", 0.87, 0.79, 0.96), ("橙", 1, 0.85, 0.65),
      ("粉", 1, 0.84, 0.92), ("青", 0.72, 0.93, 0.94), ("黑", 0.77, 0.77, 0.77),
      ("白", 1, 1, 1),
    ]
    let exactName = name.hasSuffix("色") ? String(name.dropLast()) : name
    let selected = colors.first { $0.0 == exactName } ?? colors[index % 8]
    return CGColor(red: selected.1, green: selected.2, blue: selected.3, alpha: 1)
  }

  private static func relationText(_ relation: MathDiagram.Relation, facts: [String: MathDiagram.Fact]) -> String {
    let symbol: String
    switch relation.operation { case .sum: symbol = " + "; case .difference: symbol = " − "; case .product: symbol = " × "; case .quotient: symbol = " ÷ "; case .equal: symbol = ""; case .floorQuotient: symbol = " 整除 "; case .remainder: symbol = " 求余数 " }
    func label(_ id: String) -> String {
      let fact = facts[id]!
      return "\(fact.label)（\(fact.value.map(number) ?? "？")\(fact.unit)）"
    }
    return relation.inputIDs.map(label).joined(separator: symbol) + " = " + label(relation.outputID)
  }

  private static func number(_ value: Double) -> String {
    if value == value.rounded() { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
    // validate() already rejects fractions and quantities beyond six decimal places.
    // Hide binary floating-point noise in supported exact decimal quantities.
    var decimal = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    while decimal.last == "0" { decimal.removeLast() }
    if decimal.last == "." { decimal.removeLast() }
    // Never erase a nonzero value admitted by the validator's numeric tolerance.
    if decimal == "0" || decimal == "-0" { return String(value) }
    return decimal
  }
  private static func attributed(_ text: String, size: CGFloat, bold: Bool) -> NSAttributedString {
    let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    return NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink])
  }
  private static func textHeight(_ text: String, width: CGFloat, size: CGFloat, bold: Bool) -> CGFloat {
    let frameSetter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, bold: bold))
    let height = CTFramesetterSuggestFrameSizeWithConstraints(frameSetter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
    return ceil(height) + 5
  }
  private static func render(_ layout: Layout, in context: CGContext, rect: CGRect) {
    context.saveGState()
    context.clip(to: rect)
    context.translateBy(x: rect.minX, y: rect.maxY)
    let scale = min(rect.width / layout.size.width, rect.height / layout.size.height)
    context.scaleBy(x: scale, y: -scale)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: layout.size))
    context.setLineWidth(1)
    for element in layout.elements {
      switch element.shape {
      case .box(let fill, let dashed):
        context.saveGState(); context.setFillColor(fill); context.setStrokeColor(dashed ? blue : rule)
        context.setLineDash(phase: 0, lengths: dashed ? [5, 3] : [])
        context.addRect(element.frame); context.drawPath(using: .fillStroke); context.restoreGState()
      case .line(let end):
        context.setStrokeColor(blue); context.beginPath(); context.move(to: element.frame.origin); context.addLine(to: end); context.strokePath()
      case .ellipse(let fill):
        context.setFillColor(fill); context.setStrokeColor(blue)
        context.addEllipse(in: element.frame); context.drawPath(using: .fillStroke)
      case .arrow(let end):
        context.setStrokeColor(blue); context.beginPath(); context.move(to: element.frame.origin); context.addLine(to: end)
        let angle = atan2(end.y - element.frame.minY, end.x - element.frame.minX)
        for offset: CGFloat in [-0.45, 0.45] {
          context.move(to: end)
          context.addLine(to: CGPoint(x: end.x - 10 * cos(angle + offset), y: end.y - 10 * sin(angle + offset)))
        }
        context.strokePath()
      case .point:
        context.setFillColor(blue); context.fillEllipse(in: element.frame)
      case .text(let value, let size, let bold):
        context.saveGState()
        context.translateBy(x: element.frame.minX, y: element.frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let setter = CTFramesetterCreateWithAttributedString(attributed(value, size: size, bold: bold))
        let path = CGPath(rect: CGRect(origin: .zero, size: element.frame.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
      }
    }
    context.restoreGState()
  }
}
