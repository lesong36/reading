import AppKit

@MainActor
final class ScreenshotQuestionModelSettings: NSObject, NSWindowDelegate {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 590, height: 690),
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
  private var embeddedView: NSView?
  private var formInsets: [NSLayoutConstraint] = []
  private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

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
    apiPicker.setAccessibilityLabel("接口协议")
    for api in ScreenshotQuestionAPI.allCases {
      let item = NSMenuItem(title: api.title, action: nil, keyEquivalent: "")
      item.representedObject = api.rawValue
      apiPicker.menu?.addItem(item)
    }
    thinkingPicker.setAccessibilityLabel("思考强度")
    thinkingPicker.toolTip = ScreenshotQuestionThinking.help
    for thinking in ScreenshotQuestionThinking.allCases {
      let item = NSMenuItem(title: thinking.title, action: nil, keyEquivalent: "")
      item.representedObject = thinking.rawValue
      thinkingPicker.menu?.addItem(item)
    }
    directConnection.setAccessibilityLabel("此模型直连")
    directConnection.toolTip = "仅作用于这个问答模型，不修改系统代理、VPN 或 TUN；直连失败不会自动重复请求，可取消勾选后重试。"
    for (label, field) in [
      ("配置名称", name), ("服务地址（Base URL）", base), ("模型名称（Model）", model), ("API Key", key),
    ] { field.setAccessibilityLabel(label) }
    let add = NSButton(title: "新增配置", target: self, action: #selector(addConfiguration))
    let selection = NSStackView(views: [profiles, add, deleteButton])
    selection.spacing = 8
    profiles.setContentHuggingPriority(.defaultLow, for: .horizontal)
    profiles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let fallback = SettingsForm.label(
      "取词模型：" + (dictionaryModel.isEmpty ? "尚未配置" : (dictionaryModel as NSString).lastPathComponent),
      secondary: true)
    fallback.maximumNumberOfLines = 2
    fallback.lineBreakMode = .byTruncatingTail
    error.font = .systemFont(ofSize: 12)
    error.textColor = .systemRed
    error.setAccessibilityLabel("设置状态")
    error.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存并使用", target: self, action: #selector(save))
    save.keyEquivalent = "\r"
    let page = SettingsForm.page(
      title: "截图问答", subtitle: "保存常用模型，按需切换。取词释义使用独立设置。",
      contents: [
        SettingsForm.group([selection, fallback]),
        SettingsForm.group([
          SettingsForm.row("配置名称", control: name),
          SettingsForm.row("服务地址", control: base),
          SettingsForm.row("模型名称", control: model),
          SettingsForm.row("API Key", control: key),
          SettingsForm.row("接口协议", control: apiPicker),
          SettingsForm.label("不确定使用哪种接口时，可选择“自动识别”。", secondary: true),
        ]),
        SettingsForm.group([
          SettingsForm.row("思考强度", control: thinkingPicker),
          SettingsForm.label("减少思考可优先获得回答；提高强度适合复杂问题，通常需要更长时间。", secondary: true),
          directConnection,
        ]),
        SettingsForm.label("提问与原文会发送到所选模型；参考原截图时也会发送图片。API Key 仅保存在本机钥匙串。", secondary: true),
        error, SettingsForm.actions([cancelButton, save]),
      ])
    let root = panel.contentView!
    page.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(page)
    formInsets = [
      page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
      page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
      page.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
      page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
    ]
    NSLayoutConstraint.activate(formInsets)
    reloadProfiles(selected: preferences.selectedProfileID)
    loadConfiguration()
  }

  /// The host retains this controller; save and revert operate without dismissing its window.
  func makeEmbeddedView(onChange: @escaping () -> Void = {}) -> NSView {
    self.onChange = onChange
    if let embeddedView { return embeddedView }
    let view = panel.contentView!
    panel.contentView = NSView()
    embeddedView = view
    formInsets.forEach { $0.constant = 0 }
    cancelButton.title = "还原更改"
    cancelButton.keyEquivalent = ""
    return view
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
    error.textColor = .systemRed
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
    name.window?.makeFirstResponder(name)
  }

  @objc private func save() {
    error.textColor = .systemRed
    if !isNew && editingID == nil {
      preferences.useDictionaryConfiguration()
      preferences.setThinking(selectedThinking)
      preferences.setDirectConnection(directConnection.state == .on)
      didSave()
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
      isNew = false
      reloadProfiles(selected: id)
      loadConfiguration()
      didSave()
    } catch { self.error.stringValue = "无法保存问答模型：\(error.localizedDescription)" }
  }

  @objc private func removeConfiguration() {
    error.textColor = .systemRed
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

  @objc private func cancel() {
    if embeddedView != nil {
      isNew = false
      reloadProfiles(selected: preferences.selectedProfileID)
      loadConfiguration()
    } else { finish() }
  }

  private func didSave() {
    onChange?()
    if embeddedView != nil {
      error.textColor = .secondaryLabelColor
      error.stringValue = "已保存，问一问将使用此配置。"
    } else { finish() }
  }

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
