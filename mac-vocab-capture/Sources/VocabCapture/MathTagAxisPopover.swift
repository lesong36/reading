import AppKit

/// A flat selector anchored to the clicked dimension; it writes only that dimension.
@MainActor
final class MathTagAxisPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSPopoverDelegate
{
  let popover = NSPopover()
  private let store: MathQuestionStore
  private let questionID: String
  private let axis: String
  private let onSave: () -> Void
  private let search = NSSearchField()
  private let table = NSTableView()
  private let message = NSTextField(wrappingLabelWithString: "正在读取标签…")
  private let customName = NSTextField()
  private let saveButton = NSButton(title: "保存", target: nil, action: nil)
  private let clearButton = NSButton(title: "清除此维度", target: nil, action: nil)
  private var definitions: [MathTagDefinition] = []
  private var visible: [MathTagDefinition] = []
  private var chosen: [MathQuestionTag] = []
  private var isSaving = false
  private var isLoaded = false
  private var isClosed = false
  private var isInvalidated = false
  private var mutationTask: Task<Void, Never>?

  init(store: MathQuestionStore, questionID: String, axis: String, onSave: @escaping () -> Void) {
    self.store = store
    self.questionID = questionID
    self.axis = axis
    self.onSave = onSave
    super.init()
    buildContent()
    popover.behavior = .transient
    popover.delegate = self
    load()
  }

  func show(relativeTo anchor: NSView) {
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }
  func close() {
    isClosed = true
    popover.close()
  }
  func prepareForLibraryRestore() async {
    isInvalidated = true
    close()
    await mutationTask?.value
  }
  func popoverShouldClose(_ popover: NSPopover) -> Bool { isInvalidated || !isSaving }
  func popoverDidClose(_ notification: Notification) { isClosed = true }

  private func buildContent() {
    let title = MathQuestionTagRows.dimensions.first { $0.0 == axis }?.1 ?? "标签"
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 14, weight: .semibold)
    search.placeholderString = "搜索" + title
    search.delegate = self
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag")))
    table.headerView = nil
    table.rowHeight = 30
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel(title + "可选标签")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = table
    scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
    customName.placeholderString = "新增自定义标签"
    let add = NSButton(title: "添加", target: self, action: #selector(addCustom))
    let custom = NSStackView(views: [customName, add])
    custom.spacing = 8
    custom.isHidden = axis != "custom"
    customName.setContentHuggingPriority(.defaultLow, for: .horizontal)
    message.font = .systemFont(ofSize: 11)
    message.textColor = .secondaryLabelColor
    message.maximumNumberOfLines = 2
    message.heightAnchor.constraint(equalToConstant: 32).isActive = true
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.isEnabled = false
    clearButton.target = self
    clearButton.action = #selector(clear)
    clearButton.isEnabled = false
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    let controls = NSStackView(views: [clearButton, NSView(), cancel, saveButton])
    controls.spacing = 8
    let stack = NSStackView(views: [heading, search, scroll, custom, message, controls])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    let controller = NSViewController()
    controller.view = NSView(
      frame: NSRect(x: 0, y: 0, width: 430, height: axis == "custom" ? 430 : 395))
    controller.view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14),
    ])
    for view in [search, scroll, custom, message, controls] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    popover.contentViewController = controller
    popover.contentSize = controller.view.frame.size
  }

  private func load() {
    Task { [weak self, store, questionID, axis] in
      do {
        let catalogue = try MathTagCatalogue.load()
        let options = try await store.tagOptions()
        let tags = try await store.tags(questionID: questionID)
        guard let self, !self.isClosed else { return }
        self.chosen = tags.filter { $0.axis == axis && $0.status != "rejected" }
        self.definitions = catalogue.tags.filter { $0.assignment.axis == axis }
        for tag in (options + self.chosen).filter({ $0.axis == axis }) {
          if !self.definitions.contains(where: { $0.assignment.key == tag.key }) {
            self.definitions.append(
              MathTagDefinition(
                assignment: tag, definition: axis == "custom" ? "自定义标签" : "已保存的目录标签",
                boundary: "", group: ""))
          }
        }
        self.isLoaded = true
        self.saveButton.isEnabled = true
        self.clearButton.isEnabled = true
        self.reloadRows()
      } catch { self?.message.stringValue = "读取失败：" + error.localizedDescription }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let entry = visible[row]
    let checkbox = NSButton(
      checkboxWithTitle: entry.assignment.label, target: self, action: #selector(toggle(_:)))
    checkbox.tag = row
    checkbox.state = chosen.contains { $0.key == entry.assignment.key } ? .on : .off
    checkbox.isEnabled = !isSaving
    checkbox.toolTip = entry.definition + "\n" + entry.boundary
    let cell = NSTableCellView()
    cell.addSubview(checkbox)
    checkbox.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      checkbox.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
      checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
  func controlTextDidChange(_ obj: Notification) { reloadRows() }

  private func reloadRows() {
    let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    visible = definitions.filter {
      term.isEmpty
        || ($0.assignment.label + $0.definition + $0.group).localizedCaseInsensitiveContains(term)
    }
    table.reloadData()
    message.stringValue = "已选 \(chosen.count) 项 · 仅修改当前维度，其他标签保持不变"
  }

  @objc private func toggle(_ sender: NSButton) {
    guard !isSaving, visible.indices.contains(sender.tag) else { return }
    let tag = visible[sender.tag].assignment
    chosen.removeAll { $0.key == tag.key }
    if sender.state == .on {
      chosen.append(
        MathQuestionTag(
          axis: axis, tagID: tag.tagID, catalogueVersion: tag.catalogueVersion, label: tag.label))
    }
    message.stringValue = "已选 \(chosen.count) 项 · 点击保存应用修改"
  }

  @objc private func addCustom() {
    guard axis == "custom", isLoaded, !isSaving else { return }
    let name = customName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      message.stringValue = "请填写标签名称"
      return
    }
    let tag =
      definitions.first {
        $0.assignment.label.localizedCaseInsensitiveCompare(name) == .orderedSame
      }?.assignment
      ?? MathQuestionTag(
        axis: axis, tagID: "user." + UUID().uuidString, catalogueVersion: "user@1", label: name)
    chosen.removeAll { $0.key == tag.key }
    chosen.append(
      MathQuestionTag(
        axis: axis, tagID: tag.tagID, catalogueVersion: tag.catalogueVersion, label: tag.label))
    if !definitions.contains(where: { $0.assignment.key == tag.key }) {
      definitions.append(
        MathTagDefinition(assignment: tag, definition: "自定义标签", boundary: "", group: ""))
    }
    customName.stringValue = ""
    search.stringValue = ""
    reloadRows()
  }
  @objc private func clear() {
    guard isLoaded, !isSaving else { return }
    chosen = []
    reloadRows()
  }
  @objc private func cancel() {
    guard !isSaving else { return }
    close()
  }

  @objc private func save() {
    guard isLoaded, !isSaving, !isInvalidated else { return }
    isSaving = true
    saveButton.isEnabled = false
    clearButton.isEnabled = false
    table.reloadData()
    let tags = chosen
    mutationTask = Task { [weak self, store, questionID, axis] in
      guard let self, !self.isInvalidated else { return }
      do {
        try await store.updateTagAxis(questionID: questionID, axis: axis, tags: tags)
        guard !self.isInvalidated else { return }
        self.isSaving = false
        self.close()
        self.onSave()
      } catch {
        guard !self.isInvalidated else { return }
        self.isSaving = false
        self.saveButton.isEnabled = true
        self.clearButton.isEnabled = true
        self.table.reloadData()
        self.message.stringValue = "保存失败：" + error.localizedDescription
      }
    }
  }
}
