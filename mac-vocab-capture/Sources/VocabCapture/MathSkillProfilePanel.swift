import AppKit

@MainActor
final class MathSkillProfilePanel: NSObject, NSWindowDelegate {
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let onSave: () -> Void
  private let research: MathSkillProfileResearchCoordinator.Research?
  private var displayed: MathSkillProfile?
  private var researching = false
  private let researchButton = NSButton(title: "自动五项教研", target: nil, action: nil)
  private var method: MathTeachingMethod
  private var loaded: MathSkillProfile?
  private var referenceText = ""
  private var generation = UUID()
  private var invalidated = false
  private var mutation: Task<Void, Never>?
  private var loadingRevision: UUID?
  var isMutating: Bool { mutation != nil || loadingRevision != nil }
  private let trigger = NSTextView()
  private let exclusions = NSTextView()
  private let prerequisites = NSTextField()
  private let constraints = NSTextView()
  private let permissions = MathTeachingPermissionEditor()
  private let diagrams = NSPopUpButton()
  private var selectedDiagrams = Set<String>()
  private let diagramOptions: [(String, String)] = [("bar_comparison", "数量比较线段图"), ("equal_parts", "等份图"),
    ("state", "状态变化图"), ("table", "列表图"), ("area", "面积图"), ("interval", "间隔图"),
    ("part_whole", "部分与整体图"), ("venn", "集合图"), ("balance", "平衡图"), ("cycle", "周期图")]
  private let evidence = NSTextView()
  private let status = NSTextField(wrappingLabelWithString: "正在读取…")
  private let note = NSTextField()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let save = NSButton(title: "保存新版本草稿", target: nil, action: nil)
  private let approve = NSButton(title: "人工确认并启用", target: nil, action: nil)
  private let reject = NSButton(title: "需重新审校", target: nil, action: nil)
  private let revoke = NSButton(title: "撤销自动使用", target: nil, action: nil)

  init(store: MathQuestionStore, method: MathTeachingMethod, research: MathSkillProfileResearchCoordinator.Research? = nil, onSave: @escaping () -> Void = {}) {
    self.store = store; self.method = method; self.research = research; self.onSave = onSave
    panel = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 1000),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = "方法教研档案 · \(method.title)"
    panel.minSize = NSSize(width: 800, height: 1000)
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let heading = NSTextField(labelWithString: method.title)
    heading.font = .systemFont(ofSize: 19, weight: .semibold)
    status.textColor = .secondaryLabelColor
    prerequisites.placeholderString = "先修知识"
    diagrams.setAccessibilityLabel("选择可用图解")
    diagrams.addItem(withTitle: "选择可用图解（可多选）")
    for (id, title) in diagramOptions {
      let item = NSMenuItem(title: title, action: #selector(toggleDiagram(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = id
      diagrams.menu?.addItem(item)
    }
    note.placeholderString = "人工审校依据或撤销原因：核对了哪些正例、反例、步骤和学段"
    note.setAccessibilityLabel("方法人工审校依据")
    evidence.isEditable = false
    evidence.font = .systemFont(ofSize: 12)
    message.textColor = .secondaryLabelColor
    message.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    for (button, action) in [(save, #selector(saveDraft)), (approve, #selector(approveMethod)),
      (reject, #selector(rejectMethod)), (revoke, #selector(revokeMethod))] {
      button.target = self; button.action = action
    }
    researchButton.target = self; researchButton.action = #selector(researchMethod)
    let researchControls = NSStackView(views: [researchButton, NSTextField(wrappingLabelWithString: "AI 评估只提供审校依据；不会批准方法或改变人工确认。")])
    researchControls.spacing = 10
    let controls = NSStackView(views: [save, approve, reject, revoke])
    controls.spacing = 8
    MathEditorLayout.install([heading, status,
      NSTextField(labelWithString: "适用条件"), MathEditorLayout.scroll(trigger, height: 70),
      NSTextField(labelWithString: "排除条件与混淆反例"), MathEditorLayout.scroll(exclusions, height: 70),
      prerequisites, NSTextField(labelWithString: "学段、教学步骤和限制"), MathEditorLayout.scroll(constraints, height: 70),
      ] + permissions.views + [diagrams, NSTextField(labelWithString: "来源、正反例与当前版本审核记录"),
      MathEditorLayout.scroll(evidence, height: 220), researchControls, note, message, controls], in: panel)
    for (view, label) in [(trigger, "方法适用条件"), (exclusions, "方法排除条件"),
      (constraints, "方法学段限制"), (evidence, "方法来源与审核记录")] {
      view.setAccessibilityLabel(label)
    }
  }

  func present() {
    guard !invalidated else { return }
    refresh(); panel.center(); panel.bringToFront()
  }

  func prepareForLibraryRestore() async {
    invalidated = true; generation = UUID(); loadingRevision = nil
    if researching { mutation?.cancel() }
    panel.close()
    await mutation?.value
  }

  func windowWillClose(_ notification: Notification) {
    generation = UUID(); loadingRevision = nil
    if researching { mutation?.cancel() }
  }

  private func refresh() {
    let token = generation, version = method.versionID, base = method, revision = UUID()
    loadingRevision = revision
    setBusy(true)
    Task { [weak self, store] in
      do {
        let profile = try await store.skillProfile(versionID: version)
        let events = try await store.skillLifecycleEvents(versionID: version)
        let attempt = try await store.profileResearchAttempt(method: base)
        guard let self, !self.invalidated, self.generation == token, self.method.versionID == version, self.loadingRevision == revision else { return }
        let catalogue = try? MathTeachingReviewCatalogue.load()
        self.loaded = profile
        let seed = profile ?? attempt.profile
        self.displayed = seed
        self.trigger.string = seed.trigger
        self.exclusions.string = seed.exclusions
        self.prerequisites.stringValue = seed.prerequisites
        self.constraints.string = seed.constraints
        self.permissions.load(seed.teachingPermissions)
        self.selectedDiagrams = Set(seed.supportedDiagrams)
        self.updateDiagramMenu()
        let localized = ["draft": "草稿，未启用", "approved": "用户已确认，可自动使用",
          "review_required": "需重新审校，未启用", "revoked": "已撤销自动使用"]
        self.status.stringValue = "当前版本：\(version)\n" + (profile.flatMap { localized[$0.status] } ?? "项目资料待审；现有用户方法保持原使用方式。")
        let source = MathTeachingMethod(id: self.method.id, versionID: self.method.versionID,
          title: self.method.title, category: self.method.category,
          instructions: profile?.sourceInstructions ?? self.method.instructions, createdAt: self.method.createdAt)
        self.referenceText = (profile == nil ? "" : "以下来源属于原始方法；当前版本的修改仍须独立核对。\n\n")
          + (catalogue?.evidenceText(for: source) ?? "教研来源资料读取失败；请核对项目安装资源。")
        let history = events.reversed().map { event -> String in
          if event.decision == "ai_research", let archive = try? JSONDecoder().decode(MathSkillProfileResearchArchive.self, from: Data(event.note.utf8)) {
            return "\(event.createdAt.formatted()) · AI 五项教研（非人工批准） · \(archive.model)\n版本：\(archive.attempt.method.versionID)\n依据：\(archive.attempt.evidence.count) 项，其中用户确认 \(archive.attempt.evidence.filter { $0.verification == "confirmed" }.count) 项\n绑定：\(archive.result.bindingDigest)\n\n\(archive.result.summary)"
          }
          return "\(event.createdAt.formatted()) · \(localized[event.decision] ?? event.decision)\n\(event.note)"
        }.joined(separator: "\n\n")
        self.evidence.string = (history.isEmpty ? "" : "当前版本教研与人工审核记录：\n" + history + "\n\n来源与待审案例：\n") + self.referenceText
        self.evidence.scrollToBeginningOfDocument(nil)
        self.loadingRevision = nil
        self.setBusy(self.isMutating)
      } catch {
        guard let self, !self.invalidated, self.generation == token, self.loadingRevision == revision else { return }
        self.loadingRevision = nil
        self.setBusy(self.isMutating || self.displayed == nil)
        self.message.stringValue = error.localizedDescription
      }
    }
  }

  private func currentProfile() -> MathSkillProfile {
    .init(versionID: method.versionID, trigger: trigger.string.trimmingCharacters(in: .whitespacesAndNewlines),
      constraints: constraints.string.trimmingCharacters(in: .whitespacesAndNewlines),
      exclusions: exclusions.string.trimmingCharacters(in: .whitespacesAndNewlines),
      prerequisites: prerequisites.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      supportedDiagrams: (displayed?.supportedDiagrams ?? []).filter { selectedDiagrams.contains($0) }
        + diagramOptions.map(\.0).filter { selectedDiagrams.contains($0) && !(displayed?.supportedDiagrams.contains($0) ?? false) },
      status: loaded?.status ?? "draft", sourceInstructions: displayed?.sourceInstructions, teachingPermissions: permissions.optionalValue)
  }
  @objc private func toggleDiagram(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    if selectedDiagrams.contains(id) { selectedDiagrams.remove(id) } else { selectedDiagrams.insert(id) }
    updateDiagramMenu()
  }
  private func updateDiagramMenu() {
    let titles = diagramOptions.filter { selectedDiagrams.contains($0.0) }.map(\.1)
    diagrams.item(at: 0)?.title = titles.isEmpty ? "选择可用图解（可多选；也可不画图）" : "可用图解：" + titles.joined(separator: "、")
    for item in diagrams.itemArray.dropFirst() { item.state = selectedDiagrams.contains(item.representedObject as? String ?? "") ? .on : .off }
    diagrams.selectItem(at: 0)
  }

  @objc private func researchMethod() {
    guard let research, !isMutating, !invalidated else { return }
    guard displayed == currentProfile() else {
      message.stringValue = "档案内容已修改，请先保存新版本草稿，再对该版本自动教研。"; return
    }
    let token = generation, base = method
    researching = true; setBusy(true)
    message.stringValue = "正在核对数学、学段、适用条件、混淆反例和图解依据…"
    mutation = Task { [weak self] in
      defer { self?.researching = false; self?.mutation = nil }
      do {
        try await research(base)
        guard let self, !self.invalidated, self.generation == token else { return }
        self.message.stringValue = "五项教研报告已保存；请阅读依据与缺口，再进行人工审校。"
        self.researching = false; self.mutation = nil; self.onSave(); self.refresh()
      } catch {
        guard let self else { return }
        self.researching = false; self.mutation = nil
        guard !self.invalidated, self.generation == token else { return }
        self.setBusy(false); self.message.stringValue = error.localizedDescription
      }
    }
  }

  @objc private func saveDraft() {
    let profile = currentProfile(), base = method
    perform { [store] in
      let saved = try await store.saveSkillProfileRevision(method: base, profile: profile)
      return saved
    }
  }

  @objc private func approveMethod() { review(approved: true) }
  @objc private func rejectMethod() { review(approved: false) }
  private func review(approved: Bool) {
    guard let loaded, loaded == currentProfile() else {
      message.stringValue = "请先保存新版本草稿，再对当前版本进行人工确认。"; return
    }
    let reason = note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { message.stringValue = "请填写人工审校依据。"; return }
    let base = method
    perform { [store] in
      try await store.reviewCurrentSkillProfile(method: base, approved: approved, note: reason)
      return base
    }
  }

  @objc private func revokeMethod() {
    let reason = note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), base = method
    guard !reason.isEmpty else { message.stringValue = "请填写撤销原因。"; return }
    perform { [store] in
      try await store.revokeCurrentSkillMethod(method: base, note: reason)
      return base
    }
  }

  private func perform(_ operation: @escaping @Sendable () async throws -> MathTeachingMethod) {
    guard !isMutating, !invalidated else { return }
    let token = generation
    setBusy(true)
    mutation = Task { [weak self] in
      guard let self else { return }
      defer { self.mutation = nil }
      guard !self.invalidated, self.generation == token else { return }
      do {
        let saved = try await operation()
        guard !self.invalidated, self.generation == token else { return }
        self.method = saved
        self.note.stringValue = ""
        self.message.stringValue = "已保存；旧版本及其审核记录继续保留。"
        self.mutation = nil
        self.onSave(); self.refresh()
      } catch {
        guard !self.invalidated, self.generation == token else { return }
        self.mutation = nil; self.setBusy(false)
        self.message.stringValue = error.localizedDescription
      }
    }
  }

  private func setBusy(_ busy: Bool) {
    for button in [save, approve, reject, revoke] { button.isEnabled = !busy }
    for view in [trigger, exclusions, constraints] { view.isEditable = !busy }
    for field in [prerequisites, note] { field.isEnabled = !busy }
    diagrams.isEnabled = !busy
    permissions.setEnabled(!busy)
    researchButton.isEnabled = !busy && research != nil
  }
}
