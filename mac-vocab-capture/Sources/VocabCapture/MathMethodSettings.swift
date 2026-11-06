import AppKit

@MainActor
final class MathMethodSettings: NSObject, NSWindowDelegate {
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let onSave: () -> Void
  private let research: MathSkillProfileResearchCoordinator.Research?
  private let picker = NSPopUpButton()
  private let name = NSTextField()
  private let category = NSTextField()
  private let instructions = NSTextView()
  private let permissions = MathTeachingPermissionEditor()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "保存方法", target: nil, action: nil)
  private let archiveButton = NSButton(title: "停用方法", target: nil, action: nil)
  private let importButton = NSButton(title: "导入方法文件夹…", target: nil, action: nil)
  private let profileButton = NSButton(title: "教研档案…", target: nil, action: nil)
  private var profilePanel: MathSkillProfilePanel?
  private var openedProfilePanels: [MathSkillProfilePanel] = []
  private var methods: [MathTeachingMethod] = []
  private var isSaving = false
  private var revision = UUID()
  private var isInvalidated = false
  private var preparationTask: Task<Void, Never>?
  private var mutationTask: Task<Void, Never>?
  private let readDirectory: @Sendable (URL) async throws -> [MathMethodImportEntry]

  init(store: MathQuestionStore,
    readDirectory: @escaping @Sendable (URL) async throws -> [MathMethodImportEntry] = { directory in
      try await Task.detached { try MathMethodImporter.read(directory: directory) }.value
    }, research: MathSkillProfileResearchCoordinator.Research? = nil, onSave: @escaping () -> Void = {}) {
    self.store = store
    self.readDirectory = readDirectory
    self.onSave = onSave
    self.research = research
    panel = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 650, height: 640),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = "题型方法"
    panel.minSize = NSSize(width: 650, height: 640)
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    buildContent()
  }

  func present() {
    guard !isInvalidated else { return }
    refresh()
    panel.center()
    panel.bringToFront()
  }

  func prepareForLibraryRestore() async {
    isInvalidated = true
    revision = UUID()
    preparationTask?.cancel()
    for editor in openedProfilePanels { await editor.prepareForLibraryRestore() }
    openedProfilePanels.removeAll()
    for sheet in panel.sheets { panel.endSheet(sheet, returnCode: .cancel); sheet.close() }
    panel.close()
    // Preparation never mutates and need not finish before restore; already submitted
    // writes do. A late reader is rejected by the generation check before it can submit.
    await mutationTask?.value
  }

  func windowWillClose(_ notification: Notification) {
    revision = UUID()
    preparationTask?.cancel()
  }

  private func buildContent() {
    let heading = NSTextField(labelWithString: "保存自己的解题方法")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let note = NSTextField(
      wrappingLabelWithString: "问一问可自动匹配方法，也可手动指定。导入 Markdown 文件夹即可加入方法库。修改方法会保存新版本，旧回答使用的方法仍保留。")
    note.textColor = .secondaryLabelColor
    picker.target = self
    picker.action = #selector(selectMethod)
    picker.setAccessibilityLabel("编辑题型方法")
    name.placeholderString = "方法名称，例如盈亏问题"
    name.setAccessibilityLabel("方法名称")
    category.placeholderString = "适用题型／年级，例如四年级 · 盈亏问题"
    category.setAccessibilityLabel("方法适用题型")
    instructions.setAccessibilityLabel("方法步骤及适用条件")
    let explanation = NSTextField(labelWithString: "步骤、适用条件、示例与限制")
    message.textColor = .secondaryLabelColor
    message.font = .systemFont(ofSize: 12)
    message.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    saveButton.target = self
    saveButton.action = #selector(save)
    archiveButton.target = self
    archiveButton.action = #selector(archive)
    let close = NSButton(title: "关闭", target: self, action: #selector(closePanel))
    importButton.target = self
    importButton.action = #selector(importFolder)
    profileButton.target = self
    profileButton.action = #selector(openProfile)
    let controls = NSStackView(views: [importButton, profileButton, archiveButton, NSView(), close, saveButton])
    controls.spacing = 10
    MathEditorLayout.install(
      [
        heading, note, picker, name, category, explanation,
        MathEditorLayout.scroll(instructions, height: 200),
      ] + permissions.views + [message, controls,
      ], in: panel)
  }

  private func refresh(selectID: String? = nil, message: String? = nil) {
    let revision = revision
    Task { [weak self, store] in
      do {
        let entries = try await store.methods()
        guard let self, !self.isInvalidated, self.revision == revision else { return }
        self.methods = entries
        self.picker.removeAllItems()
        self.picker.addItem(withTitle: "新增方法")
        self.picker.addItems(
          withTitles: entries.map { $0.title + ($0.category.isEmpty ? "" : " · " + $0.category) })
        if let selectID, let index = entries.firstIndex(where: { $0.id == selectID }) {
          self.picker.selectItem(at: index + 1)
        }
        self.selectMethod()
        if let message { self.message.stringValue = message }
      } catch { self?.message.stringValue = "读取失败：\(error.localizedDescription)" }
    }
  }

  @objc private func selectMethod() {
    let index = picker.indexOfSelectedItem - 1
    let entry = methods.indices.contains(index) ? methods[index] : nil
    name.stringValue = entry?.title ?? ""
    category.stringValue = entry?.category ?? ""
    instructions.string = entry?.instructions ?? ""
    permissions.load(entry?.teachingPermissions)
    archiveButton.isEnabled = entry != nil && !isSaving
    profileButton.isEnabled = entry != nil && !isSaving
    let known = entry.flatMap { MathMethodMatcher.eligibilityPolicy(for: $0) }
    let unknown = known == nil || known?.source == "unknown" || (entry?.teachingPermissions != nil && entry?.teachingPermissions?.isComplete != true)
    message.stringValue = (entry.map { "版本保存于 \($0.createdAt.formatted())。" } ?? "新增方法。")
      + (unknown ? "教学权限尚未核对，仅供手动选择；请设置三项权限并在教研档案确认新版本。" : "修改后须重新人工确认；旧回答的方法快照保留。")
  }

  @objc private func save() {
    guard !isSaving, !isInvalidated else { return }
    panel.makeFirstResponder(nil)
    let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let body = instructions.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !body.isEmpty else {
      message.stringValue = "请填写方法名称和具体步骤。"
      return
    }
    let index = picker.indexOfSelectedItem - 1
    let id = methods.indices.contains(index) ? methods[index].id : nil
    let kind = category.stringValue, declaration = permissions.value
    setBusy(true)
    let revision = revision
    mutationTask = Task { [weak self, store] in
      guard let self, !self.isInvalidated, self.revision == revision else { return }
      do {
        let saved = try await store.saveMethod(
          id: id, title: title, category: kind, instructions: body, teachingPermissions: declaration)
        guard !self.isInvalidated, self.revision == revision else { return }
        self.setBusy(false)
        self.onSave()
        self.refresh(selectID: saved.id)
      } catch {
        guard !self.isInvalidated, self.revision == revision else { return }
        self.setBusy(false)
        self.message.stringValue = "保存失败：\(error.localizedDescription)"
      }
    }
  }

  @objc private func archive() {
    let index = picker.indexOfSelectedItem - 1
    guard methods.indices.contains(index), !isSaving, !isInvalidated else { return }
    let id = methods[index].id
    setBusy(true)
    let revision = revision
    mutationTask = Task { [weak self, store] in
      guard let self, !self.isInvalidated, self.revision == revision else { return }
      do {
        try await store.archiveMethod(id: id)
        guard !self.isInvalidated, self.revision == revision else { return }
        self.setBusy(false)
        self.onSave()
        self.refresh()
      } catch {
        guard !self.isInvalidated, self.revision == revision else { return }
        self.setBusy(false)
        self.message.stringValue = error.localizedDescription
      }
    }
  }

  @objc private func importFolder() {
    guard !isSaving, !isInvalidated else { return }
    let revision = revision
    let chooser = NSOpenPanel()
    chooser.title = "导入 Markdown 解题方法"
    chooser.prompt = "导入方法"
    chooser.canChooseFiles = false
    chooser.canChooseDirectories = true
    chooser.allowsMultipleSelection = false
    chooser.beginSheetModal(for: panel) { [weak self] response in
      guard response == .OK, let directory = chooser.url, let self,
        !self.isInvalidated, self.revision == revision else { return }
      self.importDirectory(directory)
    }
  }

  @discardableResult
  func importDirectory(_ directory: URL) -> Task<Void, Never>? {
    guard !isSaving, !isInvalidated else { return nil }
    setBusy(true)
    let revision = revision
    preparationTask = Task { [weak self, readDirectory] in
      do {
        let entries = try await readDirectory(directory)
        guard let self, !self.isInvalidated, self.revision == revision,
          !Task.isCancelled else { return }
        self.mutationTask = Task { [weak self, store = self.store] in
          guard let self, !self.isInvalidated, self.revision == revision else { return }
          do {
            let result = try await store.importMethods(entries)
            guard !self.isInvalidated, self.revision == revision else { return }
            self.setBusy(false)
            self.onSave()
            self.refresh(
              message:
                "新增 \(result.imported) 篇，更新 \(result.updated) 篇，未变更或已停用 \(result.skipped) 篇。保留应用内编辑 \(result.conflicts) 篇；旧版本继续保留。"
            )
          } catch {
            guard !self.isInvalidated, self.revision == revision else { return }
            self.setBusy(false)
            self.message.stringValue = "导入失败：\(error.localizedDescription)"
          }
        }
        await self.mutationTask?.value
      } catch {
        guard let self, !self.isInvalidated, self.revision == revision else { return }
        self.setBusy(false)
        self.message.stringValue = "导入失败：\(error.localizedDescription)"
      }
    }
    return preparationTask
  }

  private func setBusy(_ busy: Bool) {
    isSaving = busy
    importButton.isEnabled = !busy
    picker.isEnabled = !busy
    permissions.setEnabled(!busy)
    saveButton.isEnabled = !busy
    archiveButton.isEnabled = !busy && picker.indexOfSelectedItem > 0
    profileButton.isEnabled = !busy && picker.indexOfSelectedItem > 0
  }
  @objc private func openProfile() {
    let index = picker.indexOfSelectedItem - 1
    guard !isSaving, !isInvalidated, methods.indices.contains(index) else { return }
    profilePanel?.panel.close()
    openedProfilePanels.removeAll { !$0.panel.isVisible && !$0.isMutating }
    let entry = methods[index]
    profilePanel = MathSkillProfilePanel(store: store, method: entry, research: research) { [weak self] in
      self?.onSave()
      self?.refresh(selectID: entry.id)
    }
    if let profilePanel { openedProfilePanels.append(profilePanel) }
    profilePanel?.present()
  }
  @objc private func closePanel() { if !isSaving { panel.close() } }
}

/// Native controls shared by method editing and immutable teaching profiles.
@MainActor
final class MathTeachingPermissionEditor {
  let grade = NSPopUpButton()
  let equations = NSPopUpButton()
  let extensionPermission = NSPopUpButton()
  private var originallyMissing = true
  var views: [NSView] {
    let first = NSStackView(views: [grade, equations]); first.spacing = 10
    return [NSTextField(labelWithString: "教学权限（保存为新版本，须重新人工审校）"), first, extensionPermission]
  }
  init() {
    grade.addItems(withTitles: ["最低年级：未核对"] + (1...6).map { "最低年级：\($0)年级" })
    equations.addItems(withTitles: ["方程：未核对", "不需要方程", "需要用户明确允许方程"])
    extensionPermission.addItems(withTitles: ["拓展许可：未核对", "不需要额外拓展许可", "需要用户明确允许拓展"])
    grade.setAccessibilityLabel("方法最低适用年级")
    equations.setAccessibilityLabel("方法方程权限")
    extensionPermission.setAccessibilityLabel("方法拓展许可")
  }
  func load(_ value: MathTeachingPermissions?) {
    originallyMissing = value == nil
    grade.selectItem(at: value?.minimumGrade ?? 0)
    equations.selectItem(at: value?.equationRequirement == .notRequired ? 1 : value?.equationRequirement == .required ? 2 : 0)
    extensionPermission.selectItem(at: value?.extensionRequirement == MathTeachingPermissions.Extension.none ? 1 : value?.extensionRequirement == .explicitPermission ? 2 : 0)
  }
  var value: MathTeachingPermissions {
    .init(minimumGrade: grade.indexOfSelectedItem == 0 ? nil : grade.indexOfSelectedItem,
      equationRequirement: equations.indexOfSelectedItem == 1 ? .notRequired : equations.indexOfSelectedItem == 2 ? .required : .unknown,
      extensionRequirement: extensionPermission.indexOfSelectedItem == 1 ? .none : extensionPermission.indexOfSelectedItem == 2 ? .explicitPermission : .unknown)
  }
  var optionalValue: MathTeachingPermissions? {
    let current = value
    return originallyMissing && current.minimumGrade == nil && current.equationRequirement == .unknown && current.extensionRequirement == .unknown ? nil : current
  }
  func setEnabled(_ enabled: Bool) { for button in [grade, equations, extensionPermission] { button.isEnabled = enabled } }
}
