import AppKit

@MainActor
final class DictionarySettingsView: NSObject {
  private(set) var view: NSView = NSView()
  private let base = NSTextField()
  private let model = NSTextField()
  private let key = NSSecureTextField()
  private let thinking = NSPopUpButton()
  private let backend = NSPopUpButton()
  private let feedback = SettingsForm.label("", secondary: true)
  private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
  private var saved: AIConfiguration
  private let saveConfiguration: (AIConfiguration) throws -> Void
  private let testConfiguration: (AIConfiguration) async throws -> String
  private var testing = false

  init(configuration: AIConfiguration,
    save: @escaping (AIConfiguration) throws -> Void,
    test: @escaping (AIConfiguration) async throws -> String) {
    saved = configuration
    saveConfiguration = save
    testConfiguration = test
    super.init()
    base.placeholderString = "https://api.example.com/v1"
    model.placeholderString = "模型名称"
    base.setAccessibilityLabel("服务地址")
    model.setAccessibilityLabel("模型名称")
    key.setAccessibilityLabel("API Key")
    thinking.addItems(withTitles: ScreenshotQuestionThinking.allCases.map(\.title))
    backend.addItems(withTitles: DictionaryBackend.allCases.map(\.title))
    thinking.setAccessibilityLabel("取词思考强度")
    backend.setAccessibilityLabel("取词服务类型")
    testButton.target = self
    testButton.action = #selector(testConnection)
    let restoreButton = NSButton(title: "还原更改", target: self, action: #selector(restore))
    let saveButton = NSButton(title: "保存", target: self, action: #selector(saveChanges))
    view = SettingsForm.page(title: "取词释义", subtitle: "为选词和截图取词配置释义模型。问一问可使用独立模型。", contents: [
      SettingsForm.group([
        SettingsForm.row("服务地址", control: base), SettingsForm.row("模型名称", control: model),
        SettingsForm.row("API Key", control: key),
        SettingsForm.label("API Key 仅保存在本机钥匙串。支持 OpenAI 兼容接口和自建服务。", secondary: true),
      ]),
      SettingsForm.group([
        SettingsForm.row("服务类型", control: backend), SettingsForm.row("思考强度", control: thinking),
        SettingsForm.label("关闭或减少思考可优先获得回答。具体支持程度由模型服务决定。", secondary: true),
      ]), feedback, SettingsForm.actions([testButton, restoreButton, saveButton]),
    ])
    restore()
  }

  private func candidate() throws -> AIConfiguration {
    let configuration = try DictionaryRequestPolicy.normalized(AIConfiguration(
      baseURL: base.stringValue, model: model.stringValue, apiKey: key.stringValue,
      thinking: ScreenshotQuestionThinking.allCases[max(0, thinking.indexOfSelectedItem)],
      backend: DictionaryBackend.allCases[max(0, backend.indexOfSelectedItem)]))
    _ = try DictionaryRequestPolicy.request(selection: SelectedText(word: "test", context: "This is a test."), configuration: configuration)
    return configuration
  }

  @objc private func restore() {
    base.stringValue = saved.baseURL
    model.stringValue = saved.model
    key.stringValue = saved.apiKey
    thinking.selectItem(at: ScreenshotQuestionThinking.allCases.firstIndex(of: saved.thinking) ?? 0)
    backend.selectItem(at: DictionaryBackend.allCases.firstIndex(of: saved.backend) ?? 0)
    feedback.stringValue = ""
  }

  @objc private func saveChanges() {
    do {
      let value = try candidate()
      try saveConfiguration(value)
      saved = value
      feedback.textColor = .secondaryLabelColor
      feedback.stringValue = "已保存。"
    } catch {
      feedback.textColor = .systemRed
      feedback.stringValue = error.localizedDescription + " 原配置未改动。"
    }
  }

  @objc private func testConnection() {
    guard !testing else { return }
    do {
      let value = try candidate()
      testing = true
      testButton.isEnabled = false
      feedback.textColor = .secondaryLabelColor
      feedback.stringValue = "正在测试连接…"
      Task { [weak self] in
        guard let self else { return }
        defer { testing = false; testButton.isEnabled = true }
        do { feedback.stringValue = "连接测试通过 · \(try await testConfiguration(value))。配置尚未保存。" }
        catch { feedback.textColor = .systemRed; feedback.stringValue = error.localizedDescription }
      }
    } catch { feedback.textColor = .systemRed; feedback.stringValue = error.localizedDescription }
  }
}
