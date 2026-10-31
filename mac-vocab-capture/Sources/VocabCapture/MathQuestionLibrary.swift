import AppKit

@MainActor
final class MathQuestionLibrary: ScreenshotPanel, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private let store: MathQuestionStore
  private let reindex: @MainActor (String) -> Void
  private let search = NSSearchField()
  private let table = NSTableView()
  private let photo = NSImageView()
  private let detail = NSTextView()
  private let status = NSTextField(labelWithString: "")
  private let titleField = NSTextField()
  private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
  private let retryButton = NSButton(title: "重新索引", target: nil, action: nil)
  private let undoButton = NSButton(title: "撤销删除", target: nil, action: nil)
  private var deletedID: String?
  private var listRevision = UUID()
  private var detailRevision = UUID()
  private var requestedID: String?
  private(set) var records: [MathQuestionRecord] = []
  private(set) var selectedID: String?

  init(store: MathQuestionStore, reindex: @escaping @MainActor (String) -> Void) {
    self.store = store
    self.reindex = reindex
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    title = "数学题库"
    minSize = NSSize(width: 760, height: 560)
    isReleasedWhenClosed = false
    buildContent()
    center()
  }

  func present(questionID: String? = nil) {
    requestedID = questionID
    if questionID != nil { search.stringValue = "" }
    refresh()
    bringToFront()
  }

  func refresh() {
    let revision = UUID()
    listRevision = revision
    let query = search.stringValue
    let previous = requestedID ?? selectedID
    Task { [weak self, store] in
      do {
        let results = try await store.list(query: query)
        guard let self, self.listRevision == revision else { return }
        self.records = results
        self.table.reloadData()
        self.status.stringValue = "\(results.count) 道题目 · 原图保存在本机"
        if let previous, let row = results.firstIndex(where: { $0.id == previous }) {
          self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !results.isEmpty {
          self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
          self.table.deselectAll(nil)
        }
        self.requestedID = nil
        self.loadSelection()
      } catch {
        guard let self, self.listRevision == revision else { return }
        self.showError(error, prefix: "读取题库失败")
      }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { records.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let record = records[row]
    let label = NSTextField(
      wrappingLabelWithString:
        "\(record.title)\n\(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
    label.font = .systemFont(ofSize: 13)
    label.maximumNumberOfLines = 3
    let cell = NSTableCellView()
    cell.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }
  func controlTextDidChange(_ obj: Notification) {
    if obj.object as? NSSearchField === search { refresh() }
  }

  private func loadSelection() {
    let revision = UUID()
    detailRevision = revision
    let row = table.selectedRow
    guard records.indices.contains(row) else {
      selectedID = nil
      titleField.stringValue = ""
      photo.image = nil
      detail.string = "截图问一问后，点击“保存题目”即可收录。\n不解题也能保存原图。"
      deleteButton.isEnabled = false
      retryButton.isEnabled = false
      titleField.isEnabled = false
      return
    }
    let record = records[row]
    selectedID = record.id
    titleField.stringValue = record.title
    titleField.isEnabled = true
    deleteButton.isEnabled = true
    retryButton.isEnabled = true
    photo.image = nil
    detail.string = "正在读取原图…"
    Task { [weak self, store] in
      do {
        let image = try await store.originalImage(questionID: record.id)
        let solutions = try await store.solutions(questionID: record.id)
        guard let self, self.detailRevision == revision else { return }
        self.photo.image = NSImage(data: image)
        let indexDescription =
          record.ocrStatus == "ready"
          ? "索引已完成" : (record.ocrStatus == "failed" ? "索引失败，可重新索引" : "索引待完成")
        let answers = solutions.map {
          "提问：\($0.question)\n\($0.answer)\n模型：\($0.model) · \($0.createdAt.formatted())"
        }.joined(separator: "\n\n────────\n\n")
        self.detail.string =
          "原图 \(record.imageWidth) × \(record.imageHeight) · \(indexDescription)\n\n"
          + (answers.isEmpty ? "尚未保存解题过程。" : "AI 回答（尚未核实）\n\n" + answers) + "\n\n检索文字（以原图为准）\n"
          + (record.ocrText.isEmpty ? "暂无检索文字" : record.ocrText)
      } catch {
        guard let self, self.detailRevision == revision else { return }
        self.detail.string = "原图读取失败：\(error.localizedDescription)"
      }
    }
  }

  @objc private func renameSelected() {
    guard let id = selectedID else { return }
    let name = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    Task {
      do {
        try await store.rename(questionID: id, title: name)
        refresh()
      } catch { showError(error, prefix: "修改标题失败") }
    }
  }

  @objc private func deleteSelected() {
    guard let id = selectedID else { return }
    Task {
      do {
        try await store.delete(questionID: id)
        deletedID = id
        undoButton.isHidden = false
        refresh()
      } catch { showError(error, prefix: "删除失败") }
    }
  }

  @objc private func undoDeletion() {
    guard let id = deletedID else { return }
    Task {
      do {
        try await store.restore(questionID: id)
        deletedID = nil
        undoButton.isHidden = true
        requestedID = id
        refresh()
      } catch { showError(error, prefix: "恢复失败") }
    }
  }

  @objc private func retryIndex() {
    guard let id = selectedID else { return }
    reindex(id)
    status.stringValue = "正在重新识别索引，原图已保存。"
  }

  @objc private func viewOriginal() {
    guard let image = photo.image else { return }
    let panel = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    panel.title = "题目原图"
    panel.isReleasedWhenClosed = false
    let imageView = NSImageView()
    imageView.image = image
    imageView.imageScaling = .scaleNone
    imageView.setFrameSize(image.size)
    let scroll = NSScrollView()
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.documentView = imageView
    panel.contentView = scroll
    originalPanel?.close()
    originalPanel = panel
    panel.center()
    panel.bringToFront()
  }
  private var originalPanel: ScreenshotPanel?

  @objc private func backupLibrary() {
    let chooser = NSOpenPanel()
    chooser.canChooseFiles = false
    chooser.canChooseDirectories = true
    chooser.canCreateDirectories = true
    chooser.prompt = "备份到此处"
    chooser.message = "创建包含数据库和原照片的完整备份。"
    chooser.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let location = chooser.url, let self else { return }
      let destination = location.appendingPathComponent("数学题库备份-\(UUID().uuidString.prefix(8))")
      Task {
        do {
          try await self.store.backup(to: destination)
          self.status.stringValue = "完整备份已保存：\(destination.lastPathComponent)"
          NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { self.showError(error, prefix: "备份失败") }
      }
    }
  }

  private func showError(_ error: Error, prefix: String) {
    status.stringValue = "\(prefix)：\(error.localizedDescription)"
  }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let result = NSButton(title: title, target: self, action: action)
    result.bezelStyle = .rounded
    return result
  }

  private func buildContent() {
    search.placeholderString = "搜索标题或题目文字"
    search.delegate = self
    search.widthAnchor.constraint(equalToConstant: 270).isActive = true
    let toolbar = NSStackView(views: [
      search, button("刷新", #selector(refreshAction)),
      button("完整备份…", #selector(backupLibrary)),
    ])
    toolbar.spacing = 10
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("question"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 64
    table.style = .sourceList
    table.delegate = self
    table.dataSource = self
    let sidebar = NSScrollView()
    sidebar.hasVerticalScroller = true
    sidebar.documentView = table
    sidebar.widthAnchor.constraint(equalToConstant: 240).isActive = true
    titleField.placeholderString = "题目标题（回车保存）"
    titleField.target = self
    titleField.action = #selector(renameSelected)
    titleField.font = .systemFont(ofSize: 17, weight: .semibold)
    photo.imageScaling = .scaleProportionallyUpOrDown
    photo.heightAnchor.constraint(equalToConstant: 260).isActive = true
    detail.isEditable = false
    detail.isSelectable = true
    detail.font = .systemFont(ofSize: 14)
    detail.textContainerInset = NSSize(width: 12, height: 12)
    detail.autoresizingMask = [.width]
    detail.isVerticallyResizable = true
    detail.textContainer?.widthTracksTextView = true
    let answers = NSScrollView()
    answers.borderType = .bezelBorder
    answers.hasVerticalScroller = true
    answers.documentView = detail
    deleteButton.target = self
    deleteButton.action = #selector(deleteSelected)
    retryButton.target = self
    retryButton.action = #selector(retryIndex)
    undoButton.target = self
    undoButton.action = #selector(undoDeletion)
    undoButton.isHidden = true
    for b in [deleteButton, retryButton, undoButton] { b.bezelStyle = .rounded }
    let actions = NSStackView(views: [
      button("查看原图", #selector(viewOriginal)), retryButton,
      deleteButton, undoButton,
    ])
    actions.spacing = 10
    let right = NSStackView(views: [titleField, photo, actions, answers])
    right.orientation = .vertical
    right.alignment = .leading
    right.spacing = 12
    for v in [titleField, photo, answers] {
      v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
    }
    let body = NSStackView(views: [sidebar, right])
    body.spacing = 18
    body.alignment = .top
    sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    right.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    let layout = NSStackView(views: [toolbar, body, status])
    layout.orientation = .vertical
    layout.alignment = .leading
    layout.spacing = 16
    let root = NSView()
    root.addSubview(layout)
    layout.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
      layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      body.widthAnchor.constraint(equalTo: layout.widthAnchor),
      status.widthAnchor.constraint(equalTo: layout.widthAnchor),
    ])
    contentView = root
  }
  @objc private func refreshAction() { refresh() }
}
