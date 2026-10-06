import AppKit

@MainActor
final class ScreenshotQuestionModelSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 550, height: 765),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
  private let preferences: ScreenshotQuestionPreferences
  private let profiles = NSPopUpButton()
  private let apiPicker = NSPopUpButton()
  private let thinkingPicker = NSPopUpButton()
  private let directConnection = NSButton(
    checkboxWithTitle: "此模型直连（跳过系统 HTTP 代理）", target: nil, action: nil)
  private let name = NSTextField()
  private let base = NSTextField()
  private let model = NSTextField()
  private let key = NSSecureTextField()
  private let error = NSTextField(wrappingLabelWithString: "")
  private let deleteButton = NSButton(title: "删除配置", target: nil, action: nil)
  private var editingID: String?
  private var isNew = false
  private var confirmingDelete = false
  private var onChange: (() -> Void)?
  private var onClose: (() -> Void)?

  init(preferences: ScreenshotQuestionPreferences, dictionaryModel: String) {
    self.preferences = preferences
    super.init()
    panel.title = "问一问模型设置"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.delegate = self
    profiles.target = self
    profiles.action = #selector(selectConfiguration)
    profiles.setAccessibilityLabel("已保存的模型配置")
    deleteButton.target = self
    deleteButton.action = #selector(removeConfiguration)
    base.placeholderString = "https://api.example.com/v1"
    model.placeholderString = "填写服务提供的模型名称"
    name.placeholderString = "例如：日常问答、语法分析、本地模型"
    key.placeholderString = "本地服务通常可留空"
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 9
    column.translatesAutoresizingMaskIntoConstraints = false
    let root = panel.contentView!
    root.addSubview(column)
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      column.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
    ])
    let heading = NSTextField(labelWithString: "保存多个模型，随时切换")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    column.addArrangedSubview(heading)
    column.addArrangedSubview(
      NSTextField(
        wrappingLabelWithString:
          "每个配置可使用不同的服务、模型和 Key。保存后用于“问一问”，取词释义保持原设置。"))
    let add = NSButton(title: "新增配置", target: self, action: #selector(addConfiguration))
    let selection = NSStackView(views: [profiles, add, deleteButton])
    selection.spacing = 8
    selection.distribution = .fill
    profiles.setContentHuggingPriority(.defaultLow, for: .horizontal)
    column.addArrangedSubview(selection)
    let fallback = NSTextField(
      wrappingLabelWithString:
        "沿用取词模型："
        + (dictionaryModel.isEmpty ? "尚未配置" : (dictionaryModel as NSString).lastPathComponent))
    fallback.textColor = .secondaryLabelColor
    fallback.font = .systemFont(ofSize: 12)
    fallback.maximumNumberOfLines = 2
    fallback.lineBreakMode = .byTruncatingTail
    column.addArrangedSubview(fallback)
    column.addArrangedSubview(NSTextField(labelWithString: "接口协议"))
    apiPicker.setAccessibilityLabel("接口协议")
    for api in ScreenshotQuestionAPI.allCases {
      let item = NSMenuItem(title: api.title, action: nil, keyEquivalent: "")
      item.representedObject = api.rawValue
      apiPicker.menu?.addItem(item)
    }
    column.addArrangedSubview(apiPicker)
    column.addArrangedSubview(NSTextField(labelWithString: "思考强度"))
    thinkingPicker.setAccessibilityLabel("思考强度")
    thinkingPicker.toolTip = ScreenshotQuestionThinking.help
    for thinking in ScreenshotQuestionThinking.allCases {
      let item = NSMenuItem(title: thinking.title, action: nil, keyEquivalent: "")
      item.representedObject = thinking.rawValue
      thinkingPicker.menu?.addItem(item)
    }
    column.addArrangedSubview(thinkingPicker)
    let thinkingNote = NSTextField(wrappingLabelWithString: ScreenshotQuestionThinking.help)
    thinkingNote.font = .systemFont(ofSize: 12)
    thinkingNote.textColor = .secondaryLabelColor
    column.addArrangedSubview(thinkingNote)
    directConnection.setAccessibilityLabel("此模型直连")
    directConnection.toolTip = "仅作用于这个问答模型，不修改系统代理、VPN 或 TUN；直连失败不会自动重复请求，可取消勾选后重试。"
    column.addArrangedSubview(directConnection)
    for (label, field) in [
      ("配置名称", name), ("服务地址（Base URL）", base), ("模型名称（Model）", model), ("API Key", key),
    ] {
      column.addArrangedSubview(NSTextField(labelWithString: label))
      field.setAccessibilityLabel(label)
      field.heightAnchor.constraint(equalToConstant: 26).isActive = true
      column.addArrangedSubview(field)
    }
    let note = NSTextField(
      wrappingLabelWithString:
        "自动识别 aicodewith 的 Claude 和 GPT 接口，其他服务默认使用 Chat Completions。提问和识别原文会发到所选服务；勾选参考原截图时也会发送图片。各配置的 Key 分别存入本机 Keychain。"
    )
    note.font = .systemFont(ofSize: 12)
    note.textColor = .secondaryLabelColor
    column.addArrangedSubview(note)
    error.font = .systemFont(ofSize: 12)
    error.textColor = .systemRed
    error.setAccessibilityLabel("设置状态")
    error.heightAnchor.constraint(equalToConstant: 32).isActive = true
    column.addArrangedSubview(error)
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
    cancel.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存并使用", target: self, action: #selector(save))
    save.keyEquivalent = "\r"
    let actions = NSStackView(views: [NSView(), cancel, save])
    actions.spacing = 10
    column.addArrangedSubview(actions)
    for view in column.arrangedSubviews where view !== heading {
      view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    reloadProfiles(selected: preferences.selectedProfileID)
    loadConfiguration()
  }

  func present(onChange: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
    self.onChange = onChange
    self.onClose = onClose
    show()
  }

  func show() {
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(isNew || editingID != nil ? name : profiles)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancel()
    return false
  }

  private func reloadProfiles(selected id: String?) {
    profiles.removeAllItems()
    profiles.addItem(withTitle: "沿用取词模型")
    for profile in preferences.profiles {
      // Distinct IDs keep identically named configurations selectable.
      let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
      item.representedObject = profile.id
      profiles.menu?.addItem(item)
    }
    if let id, !preferences.profiles.contains(where: { $0.id == id }) {
      let unavailable = NSMenuItem(title: "模型配置不可用", action: nil, keyEquivalent: "")
      unavailable.representedObject = id
      profiles.menu?.addItem(unavailable)
    }
    profiles.select(profiles.itemArray.first { $0.representedObject as? String == id })
  }

  @objc private func selectConfiguration() {
    isNew = false
    loadConfiguration()
  }

  private func loadConfiguration() {
    editingID = profiles.selectedItem?.representedObject as? String
    let profile = preferences.profiles.first { $0.id == editingID }
    let configuration = editingID.map { preferences.configuration(for: $0) }
    apiPicker.select(
      apiPicker.itemArray.first {
        $0.representedObject as? String == (profile?.api ?? .automatic).rawValue
      })
    selectThinking(profile?.thinking ?? preferences.fallbackThinking)
    directConnection.state =
      (profile?.directConnection ?? preferences.fallbackDirectConnection) ? .on : .off
    name.stringValue = profile?.name ?? ""
    base.stringValue = configuration?.baseURL ?? ""
    model.stringValue = configuration?.model ?? ""
    key.stringValue = configuration?.apiKey ?? ""
    refreshEditor()
  }

  private func refreshEditor() {
    confirmingDelete = false
    deleteButton.title = "删除配置"
    deleteButton.isEnabled = editingID != nil && !isNew
    for field in [name, base, model, key] { field.isEnabled = isNew || editingID != nil }
    apiPicker.isEnabled = isNew || editingID != nil
    error.stringValue = ""
  }

  @objc private func addConfiguration() {
    isNew = true
    apiPicker.selectItem(at: 0)
    selectThinking(.off)
    directConnection.state = .off
    editingID = nil
    name.stringValue = ScreenshotQuestionPreferences.defaultProfile.name
    base.stringValue = ScreenshotQuestionPreferences.defaultProfile.baseURL
    model.stringValue = ScreenshotQuestionPreferences.defaultProfile.model
    key.stringValue = ""
    profiles.select(nil)
    refreshEditor()
    panel.makeFirstResponder(name)
  }

  @objc private func save() {
    if !isNew && editingID == nil {
      preferences.useDictionaryConfiguration()
      preferences.setThinking(selectedThinking)
      preferences.setDirectConnection(directConnection.state == .on)
      onChange?()
      finish()
      return
    }
    let trimmedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let configuration = AIConfiguration(
      baseURL: base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      model: model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
      apiKey: key.stringValue)
    guard !trimmedName.isEmpty else {
      error.stringValue = "请为配置填写名称。"
      return
    }
    guard let url = URL(string: configuration.baseURL),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else {
      error.stringValue = "请输入有效的 http 或 https 服务地址。"
      return
    }
    guard !configuration.model.isEmpty else {
      error.stringValue = "请填写模型名称。"
      return
    }
    do {
      let id = try preferences.saveProfile(
        id: editingID, name: trimmedName, configuration: configuration,
        api: ScreenshotQuestionAPI(
          rawValue: apiPicker.selectedItem?.representedObject as? String ?? "") ?? .automatic,
        thinking: selectedThinking, directConnection: directConnection.state == .on)
      preferences.selectProfile(id)
      onChange?()
      finish()
    } catch { self.error.stringValue = "无法保存问答模型：\(error.localizedDescription)" }
  }

  @objc private func removeConfiguration() {
    guard let editingID else { return }
    if !confirmingDelete {
      confirmingDelete = true
      deleteButton.title = "确认删除"
      error.stringValue = "再次点击“确认删除”将移除此配置及其 Key。"
      return
    }
    do {
      try preferences.removeProfile(id: editingID)
      reloadProfiles(selected: preferences.selectedProfileID)
      loadConfiguration()
      onChange?()
    } catch {
      confirmingDelete = false
      deleteButton.title = "删除配置"
      self.error.stringValue = "无法删除配置：\(error.localizedDescription)"
    }
  }

  @objc private func cancel() { finish() }

  private var selectedThinking: ScreenshotQuestionThinking {
    ScreenshotQuestionThinking(
      rawValue: thinkingPicker.selectedItem?.representedObject as? String ?? "") ?? .off
  }

  private func selectThinking(_ thinking: ScreenshotQuestionThinking) {
    thinkingPicker.select(
      thinkingPicker.itemArray.first { $0.representedObject as? String == thinking.rawValue })
  }

  private func finish() {
    panel.orderOut(nil)
    onChange = nil
    let callback = onClose
    onClose = nil
    callback?()
  }
}
