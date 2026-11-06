import AppKit

/// A single readable source packet; opening it grants no verification or reuse.
@MainActor
final class MathSkillEvidenceReviewPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let candidateID: String
  private let onChange: () -> Void
  private var package: MathSkillEvidenceReviewPackage?
  private var records: [MathQuestionRecord] = []
  private var photos: [String: Data] = [:]
  private var boundaries: [String: String] = [:]
  private var answerStatuses: [String: String] = [:]
  private var corrections: [String: String] = [:]
  private var previewData: [String: (Data, String)] = [:]
  private var imagePanel: ScreenshotPanel?
  private let addPicker = NSPopUpButton()
  private let note = NSTextField()
  private let confirmation = NSButton(checkboxWithTitle: "我已检查原题、答案步骤、图解和 App 展示；发现的问题已写明", target: nil, action: nil)
  private let message = NSTextField(wrappingLabelWithString: "正在读取当前版本与原题…")
  private let save = NSButton(title: "一次保存已审核依据", target: nil, action: nil)
  private var invalidated = false
  private var busy = false

  init(store: MathQuestionStore, candidateID: String, onChange: @escaping () -> Void = {}) {
    self.store = store; self.candidateID = candidateID; self.onChange = onChange
    panel = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = "人工内容审核"; panel.minSize = NSSize(width: 740, height: 620)
    panel.isReleasedWhenClosed = false; panel.delegate = self
    note.placeholderString = "填写审核意见、错误说明或需要修改的地方（必填）"
    note.setAccessibilityLabel("整包人工核验说明")
    confirmation.state = .off
    confirmation.setAccessibilityLabel(confirmation.title)
    save.target = self; save.action = #selector(confirm); save.bezelStyle = .rounded
    save.setAccessibilityLabel(save.title)
    addPicker.setAccessibilityLabel("从题库补充审核题目")
    rebuild()
  }

  func present() {
    guard !invalidated else { return }
    panel.center(); panel.bringToFront()
    Task { [weak self, store, candidateID] in
      do {
        let package = try await store.loadSkillEvidenceReview(candidateID: candidateID)
        let records = try await store.list()
        var photos: [String: Data] = [:]
        for source in package.sources {
          photos[source.questionID] = try await store.originalImage(questionID: source.questionID)
          for reference in source.references {
            if let assetID = reference.imageAssetID { photos[assetID] = try await store.assetImage(assetID: assetID) }
          }
        }
        guard let self, !self.invalidated else { return }
        self.package = package; self.records = records; self.photos = photos
        self.message.stringValue = "请只审核最终可见内容：原题、答案步骤、图解和 App 展示。系统会自动检查内部数据一致性；方法适用性可以暂不判断。"
        self.rebuild()
      } catch { self?.message.stringValue = error.localizedDescription }
    }
  }
  func invalidate() { invalidated = true; imagePanel?.close(); panel.close() }
  func windowWillClose(_ notification: Notification) { invalidated = true; imagePanel?.close() }

  private func text(_ value: String, heading: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: value)
    field.isSelectable = true
    field.font = heading ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 14)
    field.setContentHuggingPriority(.required, for: .vertical)
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
  }
  private func photo(_ data: Data, label: String) -> NSView? {
    guard let image = NSImage(data: data) else { return nil }
    let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityLabel(label)
    view.heightAnchor.constraint(equalToConstant: min(240, max(100, image.size.height))).isActive = true
    let key = UUID().uuidString
    previewData[key] = (data, label)
    let open = NSButton(title: "放大查看 · " + label, target: self, action: #selector(previewImage(_:)))
    open.identifier = NSUserInterfaceItemIdentifier(key); open.bezelStyle = .rounded
    let group = NSStackView(views: [view, open]); group.orientation = .vertical; group.alignment = .leading
    view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
    return group
  }
  @objc private func previewImage(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue, let (data, title) = previewData[key],
      let image = NSImage(data: data) else { return }
    let viewer = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    viewer.title = title; viewer.isReleasedWhenClosed = false
    let view = NSImageView(frame: NSRect(origin: .zero, size: image.size))
    view.image = image; view.imageScaling = .scaleNone
    let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
    scroll.documentView = view; viewer.contentView = scroll
    imagePanel?.close(); imagePanel = viewer; viewer.center(); viewer.bringToFront()
  }
  private func rebuild() {
    previewData.removeAll()
    let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
    func append(_ view: NSView) { column.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
    append(text("人工内容审核 · 只确认最终可见结果", heading: true))
    append(text("请检查原题是否读对、答案和步骤是否正确、图解是否对应题意、文字是否适合教学。PDF 是题目来源；照片、哈希、数据库和模型内部信息由系统自动处理。"))
    if let package {
      append(text(package.candidate.proposal.title, heading: true))
      for (index, source) in package.sources.enumerated() {
        let separator = NSBox(); separator.boxType = .separator; append(separator)
        append(text("题目 \(index + 1) · \(records.first { $0.id == source.questionID }?.title ?? "原题")", heading: true))
        if let data = photos[source.questionID], let view = photo(data, label: "依据原图 \(index + 1)") { append(view) }
        else { append(text("原图未能读取，不能保存本题审核；可先审核其他题。")) }
        if let latest = source.solutions.last {
          append(text("答案与讲解\n\(latest.answer)", heading: true))
          for diagram in latest.diagrams {
            if let data = try? MathDiagramRenderer.renderPNG(diagram), let view = photo(data, label: "答案图解") { append(view) }
          }
          if latest.diagrams.isEmpty, let failure = latest.diagramFailure {
            append(text("图解暂不可用：\(failure)"))
          }
        } else { append(text("本题缺少 AI 答案及过程；可先审核其他题。")) }
        let references = source.references.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !references.isEmpty { append(text("参考答案\n\(references)", heading: true)) }
        for reference in source.references {
          if let assetID = reference.imageAssetID, let data = photos[assetID],
            let view = photo(data, label: "参考答案原图") { append(view) }
        }
        let reviews = source.reviews.map { "\($0.scope) · \($0.status == "rejected" ? "已驳回：答案或过程有误" : $0.status) · \($0.note)\n错误说明或修正：\($0.correction.isEmpty ? "未填写" : $0.correction)" }.joined(separator: "\n")
        append(text("已有核验记录：\n\(reviews.isEmpty ? "暂无；本页不会默认确认" : reviews)"))
        let picker = NSPopUpButton(); picker.addItems(withTitles: ["未判断", "适用正例", "排除反例"])
        picker.identifier = NSUserInterfaceItemIdentifier(source.questionID)
        picker.setAccessibilityLabel("依据 \(index + 1) 的方法适用性")
        picker.selectItem(at: ["": 0, "applies": 1, "excluded": 2][boundaries[source.questionID] ?? ""] ?? 0)
        picker.target = self; picker.action = #selector(boundaryChanged(_:))
        let answerPicker = NSPopUpButton(); answerPicker.addItems(withTitles: ["答案及过程：未判断", "答案及过程：确认正确", "答案及过程：有误，驳回"])
        answerPicker.identifier = NSUserInterfaceItemIdentifier(source.questionID)
        answerPicker.setAccessibilityLabel("依据 \(index + 1) 的答案过程正确性")
        answerPicker.selectItem(at: ["": 0, "confirmed": 1, "rejected": 2][answerStatuses[source.questionID] ?? ""] ?? 0)
        answerPicker.target = self; answerPicker.action = #selector(answerChanged(_:))
        append(answerPicker)
        let correction = NSTextField(string: corrections[source.questionID] ?? "")
        correction.placeholderString = "错误原因或修正（驳回时必填；不会覆盖原 AI 答案）"
        correction.identifier = NSUserInterfaceItemIdentifier("correction:" + source.questionID)
        correction.setAccessibilityLabel("依据 \(index + 1) 的错误说明或修正")
        correction.delegate = self; append(correction)
        let remove = NSButton(title: "从本次核验移除", target: self, action: #selector(removeSource(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(source.questionID); remove.bezelStyle = .rounded
        remove.toolTip = "只调整本次核验包，不删除题目、自动观察或历史依据。"
        let decision = NSStackView(views: [picker, remove]); decision.spacing = 8; append(decision)
      }
    }
    addPicker.removeAllItems()
    let loaded = Set(package?.sources.map(\.questionID) ?? [])
    for record in records where !loaded.contains(record.id) {
      // Keep duplicate titles distinct and bind the original identity.
      let item = NSMenuItem(title: record.title + " · " + String(record.id.prefix(8)), action: nil, keyEquivalent: "")
      item.representedObject = record.id; addPicker.menu?.addItem(item)
    }
    let add = NSButton(title: "补充这道依据", target: self, action: #selector(addSource)); add.bezelStyle = .rounded
    let row = NSStackView(views: [addPicker, add]); row.spacing = 8; append(row)
    append(note); append(confirmation); append(message); append(save)
    save.isEnabled = package?.candidate.status == "draft" && !busy
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true
    scroll.setAccessibilityLabel("集中核验全部原图与完整解答")
    let document = MathQuestionDetailDocument()
    scroll.documentView = document; document.addSubview(column)
    document.translatesAutoresizingMaskIntoConstraints = false
    column.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      column.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
      column.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
      column.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
      column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
    ])
    panel.contentView = scroll
  }
  @objc private func boundaryChanged(_ sender: NSPopUpButton) {
    guard let id = sender.identifier?.rawValue else { return }
    boundaries[id] = ["", "applies", "excluded"][sender.indexOfSelectedItem]
    confirmation.state = .off
  }
  @objc private func answerChanged(_ sender: NSPopUpButton) {
    guard let id = sender.identifier?.rawValue else { return }
    answerStatuses[id] = ["", "confirmed", "rejected"][sender.indexOfSelectedItem]
    confirmation.state = .off
  }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let key = field.identifier?.rawValue, key.hasPrefix("correction:") else { return }
    corrections[String(key.dropFirst("correction:".count))] = field.stringValue
    confirmation.state = .off
  }
  @objc private func removeSource(_ sender: NSButton) {
    guard !busy, !invalidated, let id = sender.identifier?.rawValue else { return }
    package?.sources.removeAll { $0.questionID == id }; boundaries.removeValue(forKey: id)
    answerStatuses.removeValue(forKey: id); corrections.removeValue(forKey: id)
    confirmation.state = .off; rebuild()
  }
  @objc private func addSource() {
    guard !busy, !invalidated, let id = addPicker.selectedItem?.representedObject as? String,
      package?.sources.contains(where: { $0.questionID == id }) == false else { return }
    busy = true; save.isEnabled = false
    Task { [weak self, store] in
      defer { self?.busy = false; self?.save.isEnabled = self?.package?.candidate.status == "draft" }
      do {
        let source = try await store.learningSnapshot(questionID: id)
        let data = try await store.originalImage(questionID: id)
        var references: [String: Data] = [:]
        for reference in source.references {
          if let assetID = reference.imageAssetID { references[assetID] = try await store.assetImage(assetID: assetID) }
        }
        guard let self, !self.invalidated else { return }
        self.package?.sources.append(source); self.photos[id] = data
        self.photos.merge(references) { _, new in new }
        self.confirmation.state = .off; self.rebuild()
      } catch { self?.message.stringValue = error.localizedDescription }
    }
  }
  @objc private func confirm() {
    guard !busy, !invalidated, let package else { return }
    let items = package.sources.compactMap { source -> MathSkillEvidenceReviewItem? in
      let boundary = boundaries[source.questionID] ?? "", status = answerStatuses[source.questionID] ?? ""
      if boundary.isEmpty && status.isEmpty { return nil }
      return .init(questionID: source.questionID, boundary: boundary, answerStatus: status,
        correction: corrections[source.questionID] ?? "")
    }
    let checked = confirmation.state == .on, note = note.stringValue
    busy = true; save.isEnabled = false
    Task { [weak self, store] in
      guard let self, !self.invalidated else { return }
      do {
        try await store.confirmSkillEvidenceReview(package: package, items: items, note: note, confirmed: checked)
        guard !self.invalidated else { return }
        self.message.stringValue = "已保存所选审核结论；有误答案保留为驳回，不计入可用依据。尚未发布方法。"
        self.onChange()
        // Frozen package is consumed. Reopening requires a fresh source snapshot.
        self.confirmation.isEnabled = false
      } catch {
        guard !self.invalidated else { return }
        self.message.stringValue = error.localizedDescription
        self.busy = false; self.save.isEnabled = true
      }
    }
  }
}
