import AppKit

/// Navigation is read-only: only explicit review saves may change verification status.
enum MathReviewQueue {
  static func pendingSolutionIDs(
    _ solutions: [MathQuestionSolution], reviews: [String: [MathSolutionReview]] = [:]
  ) -> Set<String> {
    Set(solutions.filter { $0.verificationStatus == "unverified" }.map(\.id))
  }

  static func pendingCount(
    _ solutions: [MathQuestionSolution], reviews: [String: [MathSolutionReview]] = [:]
  ) -> Int { pendingSolutionIDs(solutions, reviews: reviews).count }

  static func nextID(after current: String, order: [String], pendingIDs: Set<String>) -> String? {
    guard let index = order.firstIndex(of: current) else { return nil }
    if pendingIDs.contains(current) { return current }
    return order.dropFirst(index + 1).first { pendingIDs.contains($0) }
  }
}

@MainActor
final class MathQuestionLibrary: ScreenshotPanel, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private let store: MathQuestionStore
  private let reindex: @MainActor (String) -> Void
  private let onAutoTaggingChanged: ((Bool) -> Void)?
  private let retag: ((String) -> Void)?
  private let backfillTags: (() -> Void)?
  private let restoreBackup: @MainActor (URL) async throws -> URL
  private let autoToggle = NSButton(checkboxWithTitle: "自动分类", target: nil, action: nil)
  private let taggingNote = NSTextField(wrappingLabelWithString: "")
  private let retagButton = NSButton(title: "重新分类", target: nil, action: nil)
  private let search = NSSearchField()
  private let pendingOnly = NSButton(checkboxWithTitle: "仅未审核", target: nil, action: nil)
  private let pendingSummary = NSTextField(labelWithString: "")
  private let startReviewButton = NSButton(title: "抽查核验", target: nil, action: nil)
  private var pendingCounts: [String: Int] = [:]
  private let filterSummary = NSTextField(wrappingLabelWithString: "")
  private let exportButton = NSButton(title: "导出 PDF…", target: nil, action: nil)
  private let openPDFButton = NSButton(title: "查看 PDF", target: nil, action: nil)
  private var exportPanel: MathQuestionPDFExportPanel?
  private var exportedPDF: URL?
  private let gradeFilter = NSPopUpButton()
  private let filterButton = NSButton(title: "筛选标签…", target: nil, action: nil)
  private let classification = NSTextField(wrappingLabelWithString: "")
  private let tagRows = MathQuestionTagRows()
  private var axisPopover: MathTagAxisPopover?
  private var tagEditor: MathTagEditor?
  private var filterTags: [MathQuestionTag] = []
  private var loadedTags: [MathQuestionTag] = []
  private let table = NSTableView()
  private let photo = MathQuestionPreview()
  private let detail = MathQuestionAnswerText()
  private let status = NSTextField(labelWithString: "")
  private let titleField = NSTextField()
  private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
  private let retryButton = NSButton(title: "重新索引", target: nil, action: nil)
  private let undoButton = NSButton(title: "撤销删除", target: nil, action: nil)
  private let referenceButton = NSButton(title: "参考答案…", target: nil, action: nil)
  private let reviewButton = NSButton(title: "核验答案…", target: nil, action: nil)
  private var reviewPanel: MathQuestionReviewPanel?
  private var methodSettings: MathMethodSettings?
  private var skillReviewPanel: MathSkillReviewPanel?
  private let learningChanged: ((String) -> Void)?
  private let onLearningEnabled: ((Bool) -> Void)?
  private let learningToggle = NSButton(checkboxWithTitle: "自动积累方法",target:nil,action:nil)
  private let backfillLearning: (() -> Void)?
  private let researchMethod: MathSkillProfileResearchCoordinator.Research?
  private let researchModel = NSPopUpButton()
  private let researchProfiles: () -> [ScreenshotQuestionModelProfile]
  private let selectedResearchProfile: () -> String?
  private let onResearchProfileChanged: ((String?) throws -> Void)?
  private let projectSync: MathSkillProjectSyncCoordinator?
  private let onMethodsChanged: () -> Void
  private let researchSkill: (@MainActor (String, Bool, String) async throws -> Void)?
  private var loadedSolutions: [MathQuestionSolution] = []
  private var loadedPendingSolutionIDs: Set<String> = []
  private var loadedReferences: [MathReferenceAnswer] = []
  private var deletedID: String?
  private var listRevision = UUID()
  private var detailRevision = UUID()
  private var requestedID: String?
  private(set) var records: [MathQuestionRecord] = []
  private(set) var selectedID: String?

  init(
    store: MathQuestionStore, reindex: @escaping @MainActor (String) -> Void,
    autoTaggingEnabled: Bool = true, autoTaggingModel: String = "",
    onAutoTaggingChanged: ((Bool) -> Void)? = nil, retag: ((String) -> Void)? = nil,
    backfillTags: (() -> Void)? = nil,
    restoreBackup: (@MainActor (URL) async throws -> URL)? = nil,
    learningEnabled: Bool = true, learningChanged: ((String) -> Void)? = nil,
    onLearningEnabled: ((Bool) -> Void)? = nil, backfillLearning: (() -> Void)? = nil,
    researchSkill: (@MainActor (String, Bool, String) async throws -> Void)? = nil,
    researchMethod: MathSkillProfileResearchCoordinator.Research? = nil,
    researchProfiles: @escaping () -> [ScreenshotQuestionModelProfile] = { [] },
    selectedResearchProfile: @escaping () -> String? = { nil },
    onResearchProfileChanged: ((String?) throws -> Void)? = nil,
    projectSync: MathSkillProjectSyncCoordinator? = nil, onMethodsChanged: @escaping () -> Void = {}
  ) {
    self.store = store
    self.reindex = reindex
    self.onAutoTaggingChanged = onAutoTaggingChanged
    self.retag = retag
    self.backfillTags = backfillTags
    self.restoreBackup = restoreBackup ?? { try await store.restoreBackup(from: $0) }
    self.learningChanged=learningChanged; self.onLearningEnabled=onLearningEnabled
    self.backfillLearning=backfillLearning; learningToggle.state=learningEnabled ? .on : .off
    self.researchSkill=researchSkill
    self.researchMethod=researchMethod
    self.researchProfiles=researchProfiles; self.selectedResearchProfile=selectedResearchProfile
    self.onResearchProfileChanged=onResearchProfileChanged
    self.projectSync=projectSync; self.onMethodsChanged=onMethodsChanged
    autoToggle.state = autoTaggingEnabled ? .on : .off
    taggingNote.stringValue =
      "保存后将题图发送给截图模型自动分类" + (autoTaggingModel.isEmpty ? "" : " · " + autoTaggingModel)
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    title = "数学题库"
    minSize = NSSize(width: 900, height: 760)
    setContentSize(NSSize(width: 1040, height: 800))
    isReleasedWhenClosed = false
    buildContent()
    center()
  }

  func updateAutomaticTagging(enabled: Bool, model: String) {
    autoToggle.state = enabled ? .on : .off
    taggingNote.stringValue = "保存后将题图发送给截图模型自动分类 · " + model
  }

  func present(questionID: String? = nil) {
    requestedID = questionID
    updateResearchProfiles()
    if questionID != nil {
      search.stringValue = ""
      pendingOnly.state = .off
      filterTags = []
      gradeFilter.selectItem(at: 0)
      filterButton.title = "筛选标签…"
    }
    refresh()
    bringToFront()
  }

  func refresh() { refreshReviewQueue() }

  private func refreshReviewQueue(after currentID: String? = nil, order: [String] = []) {
    let revision = UUID()
    listRevision = revision
    exportButton.isEnabled = false
    startReviewButton.isEnabled = false
    let selectedBeforeRefresh = Set(
      table.selectedRowIndexes.compactMap { records.indices.contains($0) ? records[$0].id : nil })
    let query = search.stringValue
    let grade = gradeFilter.indexOfSelectedItem == 0 ? nil : gradeFilter.indexOfSelectedItem
    let tags = filterTags
    let onlyPending = pendingOnly.state == .on
    let previous = requestedID ?? selectedID
    Task { [weak self, store] in
      do {
        let filtered = try await store.list(query: query, grade: grade, tags: tags)
        var counts: [String: Int] = [:]
        for record in filtered {
          let solutions = try await store.solutions(questionID: record.id)
          let count = MathReviewQueue.pendingCount(solutions)
          if count > 0 { counts[record.id] = count }
          guard let self, self.listRevision == revision else { return }
        }
        guard let self, self.listRevision == revision else { return }
        let results = onlyPending ? filtered.filter { counts[$0.id] != nil } : filtered
        let nextID = currentID.flatMap {
          MathReviewQueue.nextID(after: $0, order: order, pendingIDs: Set(counts.keys))
        }
        self.pendingCounts = counts
        self.pendingSummary.stringValue = "可选抽查：\(counts.count) 道未审核 · \(counts.values.reduce(0, +)) 份回答"
        self.startReviewButton.isEnabled = !counts.isEmpty
        self.records = results
        self.table.reloadData()
        self.updateFilterSummary()
        self.exportButton.isEnabled = !results.isEmpty
        let retainedRows = IndexSet(
          results.indices.filter { selectedBeforeRefresh.contains(results[$0].id) })
        if let nextID, let row = results.firstIndex(where: { $0.id == nextID }) {
          self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if self.requestedID == nil, !retainedRows.isEmpty {
          self.table.selectRowIndexes(retainedRows, byExtendingSelection: false)
        } else if let previous, let row = results.firstIndex(where: { $0.id == previous }) {
          self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !results.isEmpty {
          self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
          self.table.deselectAll(nil)
        }
        self.requestedID = nil
        self.loadSelection(openReview: nextID != nil)
        if currentID != nil, nextID == nil {
          self.status.stringValue = "已到当前审核队列末尾；没有继续向前的待核验题目。"
        }
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
        "\(record.title)\n" + (record.grade.map { "\($0)年级 · " } ?? "")
        + "\(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
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

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateSelectionStatus()
    loadSelection()
  }
  func controlTextDidChange(_ obj: Notification) {
    if obj.object as? NSSearchField === search { refresh() }
  }

  private func updateSelectionStatus() {
    status.stringValue =
      "\(records.count) 道题目 · 已选择 \(table.selectedRowIndexes.count) 道 · 按住 ⌘ 或 Shift 可多选"
  }

  private func updateFilterSummary() {
    var labels = filterTags.map { $0.axisTitle + "：" + $0.label }
    if gradeFilter.indexOfSelectedItem > 0 {
      labels.insert(gradeFilter.titleOfSelectedItem ?? "", at: 0)
    }
    if !search.stringValue.isEmpty { labels.append("搜索：" + search.stringValue) }
    if pendingOnly.state == .on { labels.append("仅未审核") }
    filterSummary.stringValue =
      labels.isEmpty ? "显示全部题目" : "同时匹配 · " + labels.joined(separator: " · ")
    filterSummary.toolTip = filterSummary.stringValue
  }

  private func loadSelection(openReview: Bool = false) {
    updateSelectionStatus()
    let revision = UUID()
    detailRevision = revision
    loadedSolutions = []
    loadedPendingSolutionIDs = []
    loadedReferences = []
    loadedTags = []
    retagButton.isEnabled = false
    axisPopover?.close()
    axisPopover = nil
    tagRows.set(grade: nil, tags: [], editable: false)
    classification.stringValue = ""
    referenceButton.isEnabled = false
    reviewButton.isEnabled = false
    let row = table.selectedRow
    guard records.indices.contains(row) else {
      selectedID = nil
      titleField.stringValue = ""
      photo.image = nil
      detail.string = pendingOnly.state == .on
        ? "当前筛选下没有未审核的回答。审核为可选操作；仅保存原图的题目不计入。"
        : (gradeFilter.indexOfSelectedItem > 0 || !filterTags.isEmpty || !search.stringValue.isEmpty
          ? "当前条件下没有题目。可修改搜索文字或清除筛选。"
          : "截图问一问后，点击“保存题目”即可收录。\n不解题也能保存原图。")
      deleteButton.isEnabled = false
      retryButton.isEnabled = false
      titleField.isEnabled = false
      return
    }
    let record = records[row]
    selectedID = record.id
    titleField.stringValue = record.title
    titleField.isEnabled = table.selectedRowIndexes.count == 1
    deleteButton.isEnabled = table.selectedRowIndexes.count == 1
    retryButton.isEnabled = true
    photo.image = nil
    detail.string = "正在读取原图…"
    Task { [weak self, store] in
      do {
        let image = try await store.originalImage(questionID: record.id)
        let solutions = try await store.solutions(questionID: record.id)
        let references = try await store.referenceAnswers(questionID: record.id)
        let tags = try await store.tags(questionID: record.id).filter { $0.status != "rejected" }
        var reviewHistory: [String: [MathSolutionReview]] = [:]
        for solution in solutions {
          reviewHistory[solution.id] = try await store.reviews(solutionID: solution.id)
        }
        guard let self, self.detailRevision == revision else { return }
        self.photo.image = NSImage(data: image)
        let indexDescription =
          record.ocrStatus == "ready"
          ? "索引已完成" : (record.ocrStatus == "failed" ? "索引失败，可重新索引" : "索引待完成")
        self.loadedSolutions = solutions
        self.loadedPendingSolutionIDs = MathReviewQueue.pendingSolutionIDs(solutions, reviews: reviewHistory)
        self.loadedReferences = references
        self.loadedTags = tags
        self.tagRows.set(
          grade: record.grade, tags: tags, editable: self.table.selectedRowIndexes.count == 1)
        self.retagButton.isEnabled =
          self.retag != nil && self.autoToggle.state == .on
          && record.automaticTagStatus != "running"
        let taggingState: String
        switch record.automaticTagStatus {
        case "pending": taggingState = self.autoToggle.state == .on ? "等待自动分类" : "自动分类已暂停"
        case "running": taggingState = "正在自动分类"
        case "ready": taggingState = "已自动分类"
        case "failed": taggingState = "自动分类失败，可重试"
        default: taggingState = "尚未自动分类"
        }
        self.classification.stringValue = taggingState + " · 点击标签或维度名称可编辑"
        self.referenceButton.isEnabled = true
        self.reviewButton.isEnabled = !solutions.isEmpty
        let bodyAttributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
        ]
        let answers = NSMutableAttributedString(string: "")
        for (index, entry) in solutions.enumerated() {
          let latestReview = reviewHistory[entry.id]?.last
          let state = entry.verificationStatus == "confirmed"
            ? (latestReview?.scope == "答案及解题过程" ? "答案及过程已确认" : "已确认：\(latestReview?.scope ?? "范围未记录") · 过程未确认")
            : entry.verificationStatus == "rejected" ? "用户标记有误" : "未审核（可选）"
          let method =
            entry.method.map { "\n参考方法建议（未确认采用）：\($0.title) · \($0.category)\n\($0.instructions)" } ?? ""
          let visual = entry.visualMethods.map {
            "\n数形结合：\($0.title) · \($0.category)\n\($0.instructions)"
          }.joined(separator: "\n")
          let reviews = (reviewHistory[entry.id] ?? []).map { review in
            let decision =
              review.status == "confirmed" ? "用户确认" : review.status == "rejected" ? "标记有误" : "恢复待核验"
            let reference = review.referenceID.flatMap { id in references.first { $0.id == id } }
            let evidence =
              reference.map { " · 依据参考答案（\($0.source.isEmpty ? "用户提供" : $0.source)）" } ?? ""
            return "\(decision) · \(review.scope)\(evidence) · \(review.createdAt.formatted())"
              + (review.note.isEmpty ? "" : "\n备注：\(review.note)")
              + (review.correction.isEmpty ? "" : "\n用户更正：\(review.correction)")
          }.joined(separator: "\n\n")
          if index > 0 { answers.append(NSAttributedString(string: "\n\n────────\n\n", attributes: bodyAttributes)) }
          answers.append(NSAttributedString(
            string: "回答 \(index + 1) · \(state)\n提问：\(entry.question)\n"
              + (entry.arithmeticNotice.map { "\($0)\n\n" } ?? "") + entry.answer, attributes: bodyAttributes))
          MathDiagramPresentation.append(entry.diagrams, failure: entry.diagramFailure, to: answers,
            width: max(280, self.detail.bounds.width - 30), fontSize: 14)
          answers.append(NSAttributedString(
            string: (entry.methodClaimWarning.map { "\n方法声明提示：\($0)" } ?? "")
              + (entry.selectionFailure.map { "\n自动选法记录（未套用方法）：\($0)" } ?? "")
              + (entry.reviewedExamples.isEmpty ? "" : "\n" + entry.reviewedExamples.map(\.displayLabel).joined(separator: "\n")
                + "\n仅记录本次提供的参考，不代表模型已采用或本题已核验。")
              + "\n模型：\(entry.model) · \(entry.createdAt.formatted())" + method + visual
              + (reviews.isEmpty ? "" : "\n\n核验记录\n" + reviews), attributes: bodyAttributes))
        }
        let referenceDescription = references.enumerated().map { index, entry in
          "参考答案 \(index + 1) · \(entry.source.isEmpty ? "用户提供" : entry.source) · \(entry.scope)\n\(entry.text)"
            + (entry.imageAssetID == nil ? "" : "\n已保存答案图片，可在参考答案窗口查看。")
        }.joined(separator: "\n\n")
        let heading =
          solutions.allSatisfy { $0.verificationStatus == "unverified" }
          ? "AI 回答（尚未核实）" : "AI 回答与用户核验"
        let rendered = NSMutableAttributedString(string:
          "原图 \(record.imageWidth) × \(record.imageHeight) · \(indexDescription)\n"
          + (record.automaticTagError.isEmpty ? "" : record.automaticTagError + "\n") + "\n"
          + (referenceDescription.isEmpty ? "" : referenceDescription + "\n\n────────\n\n")
          + (answers.length == 0 ? "尚未保存解题过程。" : heading + "\n\n"), attributes: bodyAttributes)
        rendered.append(answers)
        rendered.append(NSAttributedString(string: "\n\n检索文字（以原图为准）\n"
          + (record.ocrText.isEmpty ? "暂无检索文字" : record.ocrText), attributes: bodyAttributes))
        self.detail.textStorage?.setAttributedString(rendered)
        self.detail.invalidateIntrinsicContentSize()
        if openReview, self.selectedID == record.id { self.reviewAnswers() }
      } catch {
        guard let self, self.detailRevision == revision else { return }
        self.detail.string = "原图读取失败：\(error.localizedDescription)"
      }
    }
  }

  @objc private func toggleAutomaticTags() {
    onAutoTaggingChanged?(autoToggle.state == .on)
    refresh()
  }

  @objc private func retryTags() {
    guard let id = selectedID, autoToggle.state == .on else { return }
    retag?(id)
  }

  @objc private func backfillAutomaticTags() {
    guard autoToggle.state == .on else { return }
    backfillTags?()
  }

  private func editTagAxis(_ axis: String, anchor: NSView) {
    guard let id = selectedID, table.selectedRowIndexes.count == 1 else { return }
    axisPopover?.close()
    axisPopover = MathTagAxisPopover(store: store, questionID: id, axis: axis) {
      [weak self] in self?.refresh()
    }
    axisPopover?.show(relativeTo: anchor)
  }

  private func changeQuestionGrade(_ grade: Int?) {
    guard let id = selectedID, table.selectedRowIndexes.count == 1 else { return }
    tagRows.gradePicker.isEnabled = false
    Task { [weak self, store] in
      do {
        try await store.updateQuestionGrade(questionID: id, grade: grade)
        self?.refresh()
      } catch {
        guard let self else { return }
        self.showError(error, prefix: "保存年级失败")
        self.refresh()
      }
    }
  }

  @objc private func selectGradeFilter() { refresh() }

  @objc private func editFilterTags() {
    let grade = gradeFilter.indexOfSelectedItem == 0 ? nil : gradeFilter.indexOfSelectedItem
    tagEditor = MathTagEditor(store: store, grade: grade, tags: filterTags) {
      [weak self] grade, tags in
      guard let self else { return }
      self.gradeFilter.selectItem(at: grade ?? 0)
      self.filterTags = tags
      self.filterButton.title = tags.isEmpty ? "筛选标签…" : "标签筛选（\(tags.count)）…"
      self.filterButton.toolTip = tags.map { $0.axisTitle + "：" + $0.label }.joined(separator: "\n")
      self.refresh()
    }
    tagEditor?.present(on: self)
  }

  @objc private func clearFilters() {
    pendingOnly.state = .off
    gradeFilter.selectItem(at: 0)
    search.stringValue = ""
    filterTags = []
    filterButton.title = "筛选标签…"
    filterButton.toolTip = nil
    refresh()
  }

  @objc private func addReference() {
    guard let id = selectedID else { return }
    reviewPanel = MathQuestionReviewPanel(
      store: store, questionID: id, references: loadedReferences
    ) { [weak self] in
      self?.refresh()
      self?.learningChanged?(id)
    }
    reviewPanel?.present(on: self)
  }

  @objc private func togglePendingReview() { refresh() }

  @objc private func beginPendingReview() {
    let order = records.filter { pendingCounts[$0.id] != nil }.map(\.id)
    guard let first = order.first else { return }
    refreshReviewQueue(after: first, order: order)
  }

  @objc private func reviewAnswers() {
    guard let id = selectedID, !loadedSolutions.isEmpty else { return }
    let order = records.map(\.id)
    reviewPanel = MathQuestionReviewPanel(
      store: store, questionID: id, solutions: loadedSolutions, references: loadedReferences,
      pendingSolutionIDs: loadedPendingSolutionIDs,
      onNext: { [weak self] in self?.refreshReviewQueue(after: id, order: order) }
    ) { [weak self] in self?.refresh(); self?.learningChanged?(id) }
    reviewPanel?.present(on: self)
  }

  @objc private func editMethods() {
    if methodSettings == nil { methodSettings = MathMethodSettings(store: store, research: researchMethod, onSave: onMethodsChanged) }
    methodSettings?.present()
  }

  @objc private func reviewSkills() {
    if skillReviewPanel==nil {
      skillReviewPanel=MathSkillReviewPanel(store:store,openQuestion:{[weak self] in self?.present(questionID:$0)},research:researchSkill,projectSync:projectSync,onChange:{[weak self] in self?.refresh()})
    }
    skillReviewPanel?.present()
  }
  private func updateResearchProfiles() {
    researchModel.removeAllItems()
    let follow = NSMenuItem(title: "跟随截图问答模型", action: nil, keyEquivalent: "")
    researchModel.menu?.addItem(follow)
    let selected = selectedResearchProfile()
    for profile in researchProfiles() {
      let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
      item.representedObject = profile.id
      researchModel.menu?.addItem(item)
    }
    if let selected {
      if let item = researchModel.itemArray.first(where: { $0.representedObject as? String == selected }) {
        researchModel.select(item)
      } else {
        let missing = NSMenuItem(title: "已移除的模型，请重新选择", action: nil, keyEquivalent: "")
        missing.representedObject = selected; missing.isEnabled = false
        researchModel.menu?.addItem(missing); researchModel.select(missing)
      }
    } else { researchModel.select(follow) }
  }

  @objc private func changeResearchModel() {
    do {
      try onResearchProfileChanged?(researchModel.selectedItem?.representedObject as? String)
      status.stringValue = "已更新后台教研模型；后续任务使用新选择，当前任务沿用原模型。截图解题与自动分类模型不变。"
    } catch { showError(error, prefix: "后台模型未更新") }
    updateResearchProfiles()
  }

  @objc private func toggleLearning() { onLearningEnabled?(learningToggle.state == .on) }
  @objc private func scanLearning() { backfillLearning?() }

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

  @objc private func exportPDF() {
    guard !records.isEmpty else { return }
    let selected = table.selectedRowIndexes.compactMap {
      records.indices.contains($0) ? records[$0] : nil
    }
    exportPanel = MathQuestionPDFExportPanel(
      store: store, records: records, selected: selected,
      onComplete: {
        [weak self] url, pages, count in
        self?.exportedPDF = url
        self?.openPDFButton.isHidden = false
        self?.status.stringValue = "PDF 已保存 · \(count) 道题目 · \(pages) 页 · \(url.lastPathComponent)"
      })
    exportPanel?.present(on: self)
  }

  @objc private func openExportedPDF() {
    guard let exportedPDF else { return }
    NSWorkspace.shared.open(exportedPDF)
  }

  @objc private func revealLibrary() {
    NSWorkspace.shared.activateFileViewerSelecting([
      store.directory.appendingPathComponent("questions.sqlite")
    ])
  }

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

  @objc private func restoreLibrary() {
    let chooser = NSOpenPanel()
    chooser.canChooseFiles = false
    chooser.canChooseDirectories = true
    chooser.prompt = "恢复此备份"
    chooser.message = "选择完整题库备份文件夹。恢复前会自动备份当前题库，保留原照片和核验记录。"
    chooser.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let source = chooser.url, let self else { return }
      Task {
        let controls = self.contentView.map { self.controls(in: $0) } ?? []
        let states = controls.map(\.isEnabled)
        controls.forEach { $0.isEnabled = false }
        self.listRevision = UUID()
        self.detailRevision = UUID()
        self.status.stringValue = "正在检查并恢复题库…"
        defer {
          for (control, enabled) in zip(controls, states) { control.isEnabled = enabled }
          self.refresh()
        }
        do {
          await self.prepareForLibraryRestore()
          let previous = try await self.restoreBackup(source)
          self.selectedID = nil
          self.deletedID = nil
          self.search.stringValue = ""
          self.filterTags = []
          self.pendingOnly.state = .off
          self.gradeFilter.selectItem(at: 0)
          self.filterButton.title = "筛选标签…"
          self.status.stringValue = "题库已恢复；恢复前的题库备份：\(previous.lastPathComponent)"
        } catch { self.showError(error, prefix: "恢复失败，当前题库已保留") }
      }
    }
  }

  func prepareForLibraryRestore() async {
    listRevision = UUID()
    detailRevision = UUID()
    for editor in [tagEditor?.panel, reviewPanel?.panel, exportPanel?.panel, originalPanel].compactMap({ $0 }) {
      closeEditor(editor)
    }
    await axisPopover?.prepareForLibraryRestore()
    axisPopover = nil
    await tagEditor?.prepareForLibraryRestore()
    await reviewPanel?.prepareForLibraryRestore()
    await skillReviewPanel?.prepareForLibraryRestore()
    skillReviewPanel=nil
    tagEditor = nil
    reviewPanel = nil
    exportPanel = nil
    originalPanel = nil
    let settings = methodSettings
    methodSettings = nil
    await settings?.prepareForLibraryRestore()
  }

  private func closeEditor(_ panel: NSWindow) {
    for sheet in panel.sheets { closeEditor(sheet) }
    // Cancel nested file choosers before dismissing their owning editor.
    panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    panel.close()
  }

  private func controls(in view: NSView) -> [NSControl] {
    ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap { controls(in: $0) }
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
    search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    search.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
    search.setContentHuggingPriority(.defaultLow, for: .horizontal)
    exportButton.target = self
    exportButton.action = #selector(exportPDF)
    exportButton.isEnabled = false
    exportButton.setAccessibilityLabel("导出题库为 PDF")
    exportButton.bezelStyle = .rounded
    let toolbar = NSStackView(views: [
      search, button("刷新", #selector(refreshAction)),
      button("题型方法…", #selector(editMethods)), button("完整备份…", #selector(backupLibrary)),
      button("从备份恢复…", #selector(restoreLibrary)),
      button("题库位置…", #selector(revealLibrary)), NSView(), exportButton,
    ])
    toolbar.spacing = 10
    gradeFilter.addItems(withTitles: ["所有年级", "一年级", "二年级", "三年级", "四年级", "五年级", "六年级"])
    gradeFilter.target = self
    gradeFilter.action = #selector(selectGradeFilter)
    gradeFilter.setAccessibilityLabel("按年级筛选题库")
    filterButton.target = self
    filterButton.action = #selector(editFilterTags)
    let filters = NSStackView(views: [
      gradeFilter, filterButton, button("清除筛选", #selector(clearFilters)),
    ])
    filters.spacing = 10
    learningToggle.target=self; learningToggle.action=#selector(toggleLearning)
    learningToggle.toolTip="后台检查原图与已有方法覆盖；重复结构形成待审候选，不自动批准。"
    filters.addArrangedSubview(learningToggle)
    filters.addArrangedSubview(button("方法候选与教研…",#selector(reviewSkills)))
    if backfillLearning != nil { filters.addArrangedSubview(button("检查已有题目",#selector(scanLearning))) }
    pendingOnly.target = self
    pendingOnly.action = #selector(togglePendingReview)
    pendingOnly.toolTip = "审核为可选操作，无需逐题完成。已确认答案、已标错及仅原图题目不计入；过程是否确认单独保留。"
    pendingSummary.setAccessibilityLabel("待核验题目与回答数量")
    pendingSummary.font = .systemFont(ofSize: 11)
    pendingSummary.textColor = .secondaryLabelColor
    startReviewButton.target = self
    startReviewButton.action = #selector(beginPendingReview)
    startReviewButton.bezelStyle = .rounded
    startReviewButton.isEnabled = false
    let reviewQueueRow = NSStackView(views: [pendingOnly, pendingSummary, startReviewButton])
    reviewQueueRow.spacing = 10
    filterSummary.font = .systemFont(ofSize: 11)
    filterSummary.textColor = .secondaryLabelColor
    filterSummary.maximumNumberOfLines = 2
    filterSummary.setAccessibilityLabel("当前题库筛选条件")
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("question"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 64
    table.style = .sourceList
    table.allowsMultipleSelection = true
    table.setAccessibilityLabel("题库题目列表")
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
    classification.font = .systemFont(ofSize: 12)
    classification.textColor = .secondaryLabelColor
    classification.maximumNumberOfLines = 2
    classification.setContentHuggingPriority(.defaultLow, for: .horizontal)
    classification.setAccessibilityLabel("题目分类状态")
    tagRows.onEdit = { [weak self] axis, anchor in self?.editTagAxis(axis, anchor: anchor) }
    tagRows.onGrade = { [weak self] grade in self?.changeQuestionGrade(grade) }
    photo.imageScaling = .scaleProportionallyDown
    photo.setAccessibilityLabel("题目原图预览")
    detail.isEditable = false
    detail.isSelectable = true
    detail.font = .systemFont(ofSize: 14)
    detail.textContainerInset = NSSize(width: 12, height: 12)
    detail.autoresizingMask = [.width]
    detail.isVerticallyResizable = true
    detail.textContainer?.widthTracksTextView = true
    detail.setAccessibilityLabel("题目解答与审核记录")
    deleteButton.target = self
    deleteButton.action = #selector(deleteSelected)
    retryButton.target = self
    retryButton.action = #selector(retryIndex)
    undoButton.target = self
    undoButton.action = #selector(undoDeletion)
    undoButton.isHidden = true
    for b in [deleteButton, retryButton, undoButton] { b.bezelStyle = .rounded }
    referenceButton.target = self
    referenceButton.action = #selector(addReference)
    reviewButton.target = self
    reviewButton.action = #selector(reviewAnswers)
    for b in [referenceButton, reviewButton] {
      b.bezelStyle = .rounded
      b.isEnabled = false
    }
    let actions = NSStackView(views: [
      button("查看原图", #selector(viewOriginal)), retryButton, deleteButton, undoButton,
    ])
    actions.spacing = 10
    retagButton.target = self
    retagButton.action = #selector(retryTags)
    retagButton.bezelStyle = .rounded
    retagButton.isEnabled = false
    retagButton.isHidden = retag == nil
    actions.addArrangedSubview(retagButton)
    let reviewActions = NSStackView(views: [referenceButton, reviewButton])
    reviewActions.spacing = 10
    let right = NSStackView(views: [
      titleField, tagRows, classification, photo, actions, reviewActions, detail,
    ])
    right.orientation = .vertical
    right.alignment = .leading
    right.spacing = 12
    right.setContentHuggingPriority(.required, for: .vertical)
    for view in right.arrangedSubviews {
      view.setContentHuggingPriority(.required, for: .vertical)
      view.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    for v in [titleField, tagRows, classification, photo, detail] {
      v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
    }
    let document = MathQuestionDetailDocument()
    let detailScroll = NSScrollView()
    detailScroll.setAccessibilityLabel("题目完整详情")
    detailScroll.hasVerticalScroller = true
    detailScroll.autohidesScrollers = true
    detailScroll.documentView = document
    document.addSubview(right)
    document.translatesAutoresizingMaskIntoConstraints = false
    right.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
      right.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      right.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      right.topAnchor.constraint(equalTo: document.topAnchor),
      right.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
    let body = NSStackView(views: [sidebar, detailScroll])
    body.spacing = 18
    body.alignment = .top
    sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    detailScroll.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
    detailScroll.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -258).isActive = true
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    autoToggle.target = self
    autoToggle.action = #selector(toggleAutomaticTags)
    taggingNote.font = .systemFont(ofSize: 11)
    taggingNote.textColor = .secondaryLabelColor
    let autoRow = NSStackView(views: [
      autoToggle, taggingNote, button("补齐未分类", #selector(backfillAutomaticTags)),
    ])
    autoRow.spacing = 10
    autoRow.isHidden = onAutoTaggingChanged == nil
    openPDFButton.target = self
    openPDFButton.action = #selector(openExportedPDF)
    openPDFButton.bezelStyle = .rounded
    openPDFButton.isHidden = true
    let footer = NSStackView(views: [status, NSView(), openPDFButton])
    footer.spacing = 10
    researchModel.target = self; researchModel.action = #selector(changeResearchModel)
    researchModel.setAccessibilityLabel("后台教研模型")
    researchModel.toolTip = "用于自动积累、候选审校和已有方法教研；不改变截图解题与自动分类模型。"
    researchModel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
    researchModel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    updateResearchProfiles()
    let researchRow = NSStackView(views: [NSTextField(labelWithString: "后台教研模型"), researchModel])
    researchRow.spacing = 10
    researchRow.isHidden = onResearchProfileChanged == nil
    let layout = NSStackView(views: [toolbar, filters, reviewQueueRow, researchRow, filterSummary, autoRow, body, footer])
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
      toolbar.widthAnchor.constraint(equalTo: layout.widthAnchor),
      footer.widthAnchor.constraint(equalTo: layout.widthAnchor),
      filterSummary.widthAnchor.constraint(equalTo: layout.widthAnchor),
    ])
    contentView = root
  }
  @objc private func refreshAction() { refresh() }
}

/// The outer detail document owns scrolling; text takes its complete laid-out height.
private final class MathQuestionAnswerText: NSTextView {
  override var intrinsicContentSize: NSSize {
    guard let container = textContainer, let manager = layoutManager else {
      return NSSize(width: NSView.noIntrinsicMetric, height: 48)
    }
    container.containerSize = NSSize(width: max(1, bounds.width - 2 * textContainerInset.width),
      height: .greatestFiniteMagnitude)
    manager.ensureLayout(for: container)
    return NSSize(width: NSView.noIntrinsicMetric,
      height: max(48, ceil(manager.usedRect(for: container).height + 2 * textContainerInset.height)))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(newSize.width - frame.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged { invalidateIntrinsicContentSize() }
  }

  override var string: String {
    didSet { invalidateIntrinsicContentSize() }
  }
}

/// A short screenshot should not reserve a tall, empty photo panel.
private final class MathQuestionPreview: NSImageView {
  override var image: NSImage? {
    didSet { invalidateIntrinsicContentSize() }
  }

  override var intrinsicContentSize: NSSize {
    guard let image, image.size.width > 0 else {
      return NSSize(width: NSView.noIntrinsicMetric, height: 0)
    }
    let availableWidth = max(1, bounds.width)
    let height = image.size.height * min(1, availableWidth / image.size.width)
    return NSSize(width: NSView.noIntrinsicMetric, height: min(180, ceil(height)))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(newSize.width - frame.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged { invalidateIntrinsicContentSize() }
  }
}
