import AppKit
import UniformTypeIdentifiers

@MainActor
final class MathQuestionPDFExportPanel: NSObject {
  typealias Export =
    @MainActor ([MathQuestionRecord], URL, MathQuestionPDFOptions) async throws -> Int
  typealias Destination = @MainActor (NSWindow) async -> URL?
  let panel: ScreenshotPanel
  private let records: [MathQuestionRecord]
  private let selected: [MathQuestionRecord]
  private let export: Export
  private let destination: Destination
  private let onComplete: (URL, Int, Int) -> Void
  private let scope = NSPopUpButton()
  private let solutions = NSButton(
    checkboxWithTitle: "附上 AI 解题记录（独立附录，保留核验状态）", target: nil, action: nil)
  private let message = NSTextField(wrappingLabelWithString: "")
  private let saveButton = NSButton(title: "保存 PDF…", target: nil, action: nil)
  private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
  private var isExporting = false

  init(
    store: MathQuestionStore, records: [MathQuestionRecord], selected: [MathQuestionRecord],
    export: Export? = nil, destination: Destination? = nil,
    onComplete: @escaping (URL, Int, Int) -> Void = { _, _, _ in }
  ) {
    self.records = records
    let available = Set(records.map(\.id))
    self.selected = selected.filter { available.contains($0.id) }
    self.export =
      export ?? { records, url, options in
        try await MathQuestionPDFExporter.export(
          records: records, store: store, to: url, options: options)
      }
    self.destination = destination ?? Self.chooseDestination
    self.onComplete = onComplete
    panel = ScreenshotPanel(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    panel.title = "导出题目为 PDF"
    panel.isReleasedWhenClosed = false
    buildContent()
  }

  func present(on owner: NSWindow) { owner.beginSheet(panel) }

  private func buildContent() {
    let heading = NSTextField(labelWithString: "导出题目为 PDF")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let note = NSTextField(wrappingLabelWithString: "默认导出题目原图，适合打印练习。长图自动分页，OCR 检索文字不会替代原题。")
    note.textColor = .secondaryLabelColor
    scope.addItem(withTitle: "当前筛选结果（\(records.count) 道）")
    scope.addItem(withTitle: "所选题目（\(selected.count) 道）")
    scope.lastItem?.isEnabled = !selected.isEmpty
    scope.setAccessibilityLabel("PDF 导出范围")
    solutions.setAccessibilityLabel("附上 AI 解题记录")
    solutions.state = .off
    message.textColor = .secondaryLabelColor
    message.font = .systemFont(ofSize: 12)
    message.stringValue = "支持 A4 打印。选择保存位置后开始导出。"
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.isEnabled = !records.isEmpty
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    let controls = NSStackView(views: [NSView(), cancelButton, saveButton])
    controls.spacing = 10
    MathEditorLayout.install([heading, note, scope, solutions, message, controls], in: panel)
  }

  @objc private func save() {
    guard !isExporting else { return }
    let chosen = scope.indexOfSelectedItem == 1 ? selected : records
    guard !chosen.isEmpty else { return }
    let options = MathQuestionPDFOptions(includeSolutions: solutions.state == .on)
    setBusy(true)
    Task { [weak self] in
      guard let self else { return }
      guard let url = await self.destination(self.panel) else {
        self.setBusy(false)
        self.message.stringValue = "已取消保存，尚未导出。"
        return
      }
      self.message.stringValue = "正在导出 \(chosen.count) 道题目…"
      do {
        let pages = try await self.export(chosen, url, options)
        self.onComplete(url, pages, chosen.count)
        self.setBusy(false)
        self.dismiss()
      } catch {
        self.setBusy(false)
        self.message.stringValue = "导出失败：\(error.localizedDescription)"
      }
    }
  }

  private func setBusy(_ busy: Bool) {
    isExporting = busy
    saveButton.isEnabled = !busy && !records.isEmpty
    cancelButton.isEnabled = !busy
    scope.isEnabled = !busy
    solutions.isEnabled = !busy
    panel.standardWindowButton(.closeButton)?.isEnabled = !busy
  }

  @objc private func cancel() { if !isExporting { dismiss() } }
  private func dismiss() {
    if let owner = panel.sheetParent { owner.endSheet(panel) }
    panel.close()
  }

  private static func chooseDestination(on owner: NSWindow) async -> URL? {
    let chooser = NSSavePanel()
    chooser.allowedContentTypes = [.pdf]
    chooser.canCreateDirectories = true
    chooser.nameFieldStringValue = "数学题目.pdf"
    chooser.prompt = "保存 PDF"
    return await withCheckedContinuation { continuation in
      chooser.beginSheetModal(for: owner) { result in
        continuation.resume(returning: result == .OK ? chooser.url : nil)
      }
    }
  }
}
