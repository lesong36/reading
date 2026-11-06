import AppKit

/// Every dimension stays visible, including dimensions with no assigned tags.
@MainActor
final class MathQuestionTagRows: NSStackView {
  static let dimensions = [
    ("question_form", "题目形式"), ("curriculum_knowledge", "课程知识点"),
    ("problem_family", "题型"), ("custom", "自定义"),
  ]
  let gradePicker = NSPopUpButton()
  var onEdit: ((String, NSView) -> Void)?
  var onGrade: ((Int?) -> Void)?
  private var flows: [String: MathTagFlowView] = [:]
  private var headings: [NSButton] = []

  init() {
    super.init(frame: .zero)
    orientation = .vertical
    alignment = .leading
    spacing = 7
    gradePicker.addItems(withTitles: ["未设置", "一年级", "二年级", "三年级", "四年级", "五年级", "六年级"])
    gradePicker.identifier = NSUserInterfaceItemIdentifier("MathQuestion.recordGrade")
    gradePicker.setAccessibilityLabel("当前题目年级")
    gradePicker.controlSize = .small
    gradePicker.target = self
    gradePicker.action = #selector(changeGrade)
    let gradeLabel = NSTextField(labelWithString: "年级")
    gradeLabel.font = .systemFont(ofSize: 12)
    gradeLabel.textColor = .secondaryLabelColor
    gradeLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
    let gradeRow = NSStackView(views: [gradeLabel, gradePicker])
    gradeRow.spacing = 8
    addArrangedSubview(gradeRow)
    for (axis, title) in Self.dimensions {
      let heading = NSButton(title: title, target: self, action: #selector(edit(_:)))
      heading.identifier = NSUserInterfaceItemIdentifier(axis)
      heading.isBordered = false
      heading.alignment = .left
      heading.font = .systemFont(ofSize: 12)
      heading.contentTintColor = .secondaryLabelColor
      heading.widthAnchor.constraint(equalToConstant: 84).isActive = true
      heading.toolTip = "点击编辑" + title
      headings.append(heading)
      let flow = MathTagFlowView()
      flows[axis] = flow
      let row = NSStackView(views: [heading, flow])
      row.alignment = .top
      row.spacing = 8
      addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    set(grade: nil, tags: [], editable: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func set(grade: Int?, tags: [MathQuestionTag], editable: Bool) {
    gradePicker.selectItem(at: grade ?? 0)
    gradePicker.isEnabled = editable
    for heading in headings { heading.isEnabled = editable }
    for (axis, title) in Self.dimensions {
      let entries = tags.filter { $0.axis == axis && $0.status != "rejected" }
      var buttons = entries.map { tag in
        let button = makeButton(tag.label + tag.statusSuffix, axis: axis, editable: editable)
        button.setAccessibilityLabel(title + "：" + tag.label + tag.statusSuffix)
        button.toolTip = title + "：" + tag.label + tag.statusSuffix + "\n点击编辑此维度"
        return button
      }
      let add = makeButton(entries.isEmpty ? "添加…" : "＋", axis: axis, editable: editable)
      add.setAccessibilityLabel("添加" + title + "标签")
      buttons.append(add)
      flows[axis]?.setButtons(buttons)
    }
  }

  private func makeButton(_ title: String, axis: String, editable: Bool) -> NSButton {
    let button = NSButton(title: title, target: self, action: #selector(edit(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(axis)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.font = .systemFont(ofSize: 12)
    button.isEnabled = editable
    button.cell?.lineBreakMode = .byTruncatingTail
    return button
  }

  @objc private func edit(_ sender: NSButton) {
    guard let axis = sender.identifier?.rawValue else { return }
    onEdit?(axis, sender)
  }
  @objc private func changeGrade() {
    onGrade?(gradePicker.indexOfSelectedItem == 0 ? nil : gradePicker.indexOfSelectedItem)
  }
}

/// Native chips wrap without hiding assignments or requiring a horizontal scroll.
@MainActor
final class MathTagFlowView: NSView {
  private var buttons: [NSButton] = []
  private var measuredHeight: CGFloat = 24
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
  }

  func setButtons(_ buttons: [NSButton]) {
    for view in subviews { view.removeFromSuperview() }
    self.buttons = buttons
    for button in buttons { addSubview(button) }
    needsLayout = true
    invalidateIntrinsicContentSize()
  }

  override func layout() {
    super.layout()
    let available = max(1, bounds.width)
    var x: CGFloat = 0
    var y: CGFloat = 0
    for button in buttons {
      let width = min(available, max(30, button.fittingSize.width))
      if x > 0 && x + width > available {
        x = 0
        y += 29
      }
      button.frame = NSRect(x: x, y: y, width: width, height: 24)
      x += width + 6
    }
    let height = y + 24
    if measuredHeight != height {
      measuredHeight = height
      invalidateIntrinsicContentSize()
    }
  }
}

final class MathQuestionDetailDocument: NSView {
  override var isFlipped: Bool { true }
}
