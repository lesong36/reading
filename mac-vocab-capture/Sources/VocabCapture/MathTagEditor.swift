import AppKit

/// The same selector edits one question or builds an AND filter; neither requires AI.
@MainActor
final class MathTagEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let record: MathQuestionRecord?
  private let onApply: (Int?, [MathQuestionTag]) -> Void
  private let gradePicker = NSPopUpButton()
  private let axes = NSSegmentedControl(
    labels: ["题目形式", "课程知识点", "问题类型", "自定义"], trackingMode: .selectOne, target: nil, action: nil)
  private let search = NSSearchField()
  private let table = NSTableView()
  private let selected = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let customName = NSTextField()
  private let applyButton = NSButton(title: "保存标签", target: nil, action: nil)
  private let clearButton = NSButton(title: "取消全部标签", target: nil, action: nil)
  private var definitions: [MathTagDefinition] = []
  private var visible: [MathTagDefinition] = []
  private var chosen: [MathQuestionTag]
  private var isSaving = false
  private var isInvalidated = false
  private var mutationTask: Task<Void, Never>?
  private var isLoaded = false
  private let axisIDs = ["question_form", "curriculum_knowledge", "problem_family", "custom"]

  init(
    store: MathQuestionStore, record: MathQuestionRecord? = nil, grade: Int? = nil,
    tags: [MathQuestionTag] = [], onApply: @escaping (Int?, [MathQuestionTag]) -> Void
  ) {
    self.store = store
    self.record = record
    self.chosen = tags
    self.onApply = onApply
    panel = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 740, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = record == nil ? "筛选题库" : "编辑题目标签"
    panel.minSize = NSSize(width: 640, height: 590)
    panel.isReleasedWhenClosed = false
    buildContent()
    gradePicker.selectItem(at: grade ?? record?.grade ?? 0)
    load()
  }

  func present(on owner: NSWindow) { owner.beginSheet(panel) }
  func prepareForLibraryRestore() async {
    isInvalidated = true
    dismiss()
    await mutationTask?.value
  }

  private func buildContent() {
    let heading = NSTextField(labelWithString: panel.title)
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let note = NSTextField(
      wrappingLabelWithString: record == nil
        ? "年级、标签与搜索文字组合筛选。勾选的标签必须同时满足；不选标签显示全部。"
        : "依据原题标注，可多选或暂不设置。课程知识点目录为课标映射草案，尚待教学审核。")
    note.textColor = .secondaryLabelColor
    gradePicker.addItem(withTitle: record == nil ? "所有年级" : "年级未设置")
    gradePicker.addItems(withTitles: ["一年级", "二年级", "三年级", "四年级", "五年级", "六年级"])
    gradePicker.setAccessibilityLabel("题目年级")
    let gradeRow = NSStackView(views: [NSTextField(labelWithString: "年级"), gradePicker, NSView()])
    gradeRow.spacing = 10
    selected.font = .systemFont(ofSize: 12)
    selected.textColor = .secondaryLabelColor
    selected.maximumNumberOfLines = 3
    selected.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    axes.selectedSegment = 0
    axes.target = self
    axes.action = #selector(reloadRows)
    axes.setAccessibilityLabel("标签维度")
    search.placeholderString = "搜索标签名称、定义或分类"
    search.delegate = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 60
    table.delegate = self
    table.dataSource = self
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = table
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    customName.placeholderString = "新增自定义标签，例如周末复习"
    customName.setAccessibilityLabel("自定义标签名称")
    let add = NSButton(title: "添加", target: self, action: #selector(addCustomTag))
    let customRow = NSStackView(views: [customName, add])
    customRow.spacing = 10
    customRow.isHidden = record == nil
    customName.setContentHuggingPriority(.defaultLow, for: .horizontal)
    message.font = .systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    message.maximumNumberOfLines = 3
    message.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
    message.stringValue = "正在读取标签…"
    applyButton.title = record == nil ? "应用筛选" : "保存标签"
    applyButton.target = self
    applyButton.action = #selector(apply)
    applyButton.isEnabled = false
    clearButton.title = record == nil ? "清除条件" : "取消全部标签"
    clearButton.target = self
    clearButton.action = #selector(clearTags)
    clearButton.isEnabled = false
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let controls = NSStackView(views: [clearButton, NSView(), cancel, applyButton])
    controls.spacing = 10
    MathEditorLayout.install(
      [heading, note, gradeRow, selected, axes, search, scroll, customRow, message, controls],
      in: panel)
  }

  private func load() {
    Task { [weak self, store, record] in
      do {
        let catalogue = try MathTagCatalogue.load()
        let savedOptions = try await store.tagOptions()
        let saved: [MathQuestionTag]?
        if let record { saved = try await store.tags(questionID: record.id) } else { saved = nil }
        guard let self else { return }
        if let saved { self.chosen = saved.filter { $0.status != "rejected" } }
        self.definitions = catalogue.tags
        // Existing labels and old catalogue versions stay selectable rather than disappearing.
        for entry in savedOptions + self.chosen {
          if !self.definitions.contains(where: { $0.assignment.key == entry.key }) {
            self.definitions.append(
              MathTagDefinition(
                assignment: entry,
                definition: entry.axis == "custom" ? "用户自定义分类" : "已保存的目录版本标签", boundary: "",
                group: "已保存标签"))
          }
        }
        self.isLoaded = true
        self.applyButton.isEnabled = true
        self.clearButton.isEnabled = true
        self.message.stringValue =
          self.record == nil ? "筛选人工标签与有效自动标签，不包含已移除的标签。" : "自动标签可直接检索；在此修改后，重新分类保留你的修改。"
        self.reloadRows()
      } catch { self?.message.stringValue = "读取失败：\(error.localizedDescription)" }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let definition = visible[row]
    let tag = definition.assignment
    let checkbox = NSButton(
      checkboxWithTitle: tag.label, target: self, action: #selector(toggle(_:)))
    checkbox.tag = row
    checkbox.state = chosen.contains { $0.key == tag.key } ? .on : .off
    checkbox.setAccessibilityLabel(tag.axisTitle + "：" + tag.label)
    checkbox.toolTip =
      definition.definition + (definition.boundary.isEmpty ? "" : "\n" + definition.boundary)
    let description = NSTextField(
      labelWithString: (definition.group.isEmpty ? "" : definition.group + " · ")
        + definition.definition)
    description.font = .systemFont(ofSize: 11)
    description.textColor = .secondaryLabelColor
    description.lineBreakMode = .byTruncatingTail
    description.toolTip = checkbox.toolTip
    let cell = NSTableCellView()
    let rowView = NSStackView(views: [checkbox, description])
    rowView.orientation = .vertical
    rowView.alignment = .leading
    rowView.spacing = 4
    cell.addSubview(rowView)
    rowView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
      rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      description.widthAnchor.constraint(equalTo: rowView.widthAnchor),
    ])
    return cell
  }

  func controlTextDidChange(_ obj: Notification) {
    if obj.object as? NSSearchField === search { reloadRows() }
  }

  @objc private func reloadRows() {
    let axis = axisIDs[max(0, axes.selectedSegment)]
    let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    visible = definitions.filter { entry in
      entry.assignment.axis == axis
        && (term.isEmpty
          || (entry.assignment.label + entry.definition + entry.group)
            .localizedCaseInsensitiveContains(term))
    }
    table.reloadData()
    refreshSelected()
  }

  private func refreshSelected() {
    let labels = chosen.map { $0.label + $0.statusSuffix }
    selected.stringValue =
      labels.isEmpty
      ? "尚未选择标签"
      : "已选 \(labels.count) 项：" + labels.prefix(5).joined(separator: "、")
        + (labels.count > 5 ? "…" : "")
    selected.toolTip = chosen.map { $0.axisTitle + "：" + $0.label + " · " + $0.catalogueVersion }
      .joined(separator: "\n")
  }

  @objc private func toggle(_ sender: NSButton) {
    guard !isSaving, visible.indices.contains(sender.tag) else { return }
    let tag = visible[sender.tag].assignment
    if sender.state == .on {
      chosen.removeAll { $0.key == tag.key }
      chosen.append(
        MathQuestionTag(
          axis: tag.axis, tagID: tag.tagID, catalogueVersion: tag.catalogueVersion, label: tag.label
        ))
    } else {
      chosen.removeAll { $0.key == tag.key }
    }
    refreshSelected()
    message.stringValue = visible[sender.tag].definition + " " + visible[sender.tag].boundary
  }

  @objc private func addCustomTag() {
    guard !isSaving, isLoaded else { return }
    panel.makeFirstResponder(nil)
    let name = customName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      message.stringValue = "请填写自定义标签名称。"
      return
    }
    let existing = definitions.first {
      $0.assignment.axis == "custom"
        && $0.assignment.label.localizedCaseInsensitiveCompare(name) == .orderedSame
    }
    let tag =
      existing?.assignment
      ?? MathQuestionTag(
        axis: "custom", tagID: "user." + UUID().uuidString,
        catalogueVersion: "user@1", label: name)
    if existing == nil {
      definitions.append(
        MathTagDefinition(assignment: tag, definition: "用户自定义分类", boundary: "", group: "自定义"))
    }
    if !chosen.contains(where: { $0.key == tag.key }) { chosen.append(tag) }
    customName.stringValue = ""
    search.stringValue = ""
    axes.selectedSegment = 3
    reloadRows()
  }

  @objc private func clearTags() {
    guard isLoaded, !isSaving else { return }
    chosen = []
    if record == nil { gradePicker.selectItem(at: 0) }
    reloadRows()
  }

  @objc private func apply() {
    guard isLoaded, !isSaving, !isInvalidated else { return }
    let grade = gradePicker.indexOfSelectedItem == 0 ? nil : gradePicker.indexOfSelectedItem
    let tags = chosen
    guard let record else {
      onApply(grade, tags)
      dismiss()
      return
    }
    isSaving = true
    applyButton.isEnabled = false
    mutationTask = Task { [weak self, store] in
      guard let self, !self.isInvalidated else { return }
      do {
        try await store.updateClassification(questionID: record.id, grade: grade, tags: tags)
        guard !self.isInvalidated else { return }
        self.onApply(grade, tags)
        self.dismiss()
      } catch {
        guard !self.isInvalidated else { return }
        self.isSaving = false
        self.applyButton.isEnabled = true
        self.message.stringValue = "保存失败：\(error.localizedDescription)"
      }
    }
  }

  @objc private func cancel() { if !isSaving { dismiss() } }
  private func dismiss() {
    panel.sheetParent?.endSheet(panel)
    panel.close()
  }
}
