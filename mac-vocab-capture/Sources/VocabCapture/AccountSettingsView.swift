import AppKit

@MainActor
final class AccountSettingsView: NSObject {
  private(set) var view: NSView = NSView()
  private let status = SettingsForm.label("正在检查登录与同步状态…")
  private let detail = SettingsForm.label("", secondary: true)
  private let login = NSButton(title: "登录阅读达人…", target: nil, action: nil)
  private let logout = NSButton(title: "退出账号", target: nil, action: nil)
  private let sync = NSButton(title: "立即同步", target: nil, action: nil)
  private let conflicts = NSButton(title: "处理同步冲突…", target: nil, action: nil)
  private let bind = NSButton(title: "将未归属词条加入当前账号…", target: nil, action: nil)
  private let maintenance = NSButton(title: "词库维护", target: nil, action: nil)
  private let maintenanceContent: NSView
  private let actions: [() -> Void]
  private var conflictRow: NSView = NSView()
  private var bindRow: NSView = NSView()

  init(login: @escaping () -> Void, logout: @escaping () -> Void, sync: @escaping () -> Void,
    conflicts: @escaping () -> Void, bind: @escaping () -> Void,
    export: @escaping () -> Void, exportUnassigned: @escaping () -> Void, restore: @escaping () -> Void) {
    actions = [login, logout, sync, conflicts, bind, export, exportUnassigned, restore]
    func actionRow(_ title: String) -> NSView {
      let row = NSStackView(views: [NSButton(title: title, target: nil, action: nil), NSView()])
      row.alignment = .centerY
      return row
    }
    maintenanceContent = SettingsForm.group([
      SettingsForm.label("备份与恢复", secondary: true),
      actionRow("导出本机词库…"),
      actionRow("导出未归属词条…"),
      actionRow("从本机备份恢复…"),
      SettingsForm.label("恢复前会保留当前词库原件。退出或切换账号不会删除本机词条。", secondary: true),
    ])
    super.init()
    for (index, button) in [self.login, self.logout, self.sync, self.conflicts, self.bind].enumerated() {
      button.target = self; button.action = #selector(performAccountAction(_:)); button.tag = index; button.bezelStyle = .rounded
    }
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    for (index, button) in buttons(maintenanceContent).enumerated() {
      button.target = self; button.action = #selector(performAccountAction(_:)); button.tag = index + 5; button.bezelStyle = .rounded
    }
    maintenance.setButtonType(.pushOnPushOff)
    maintenance.bezelStyle = .inline
    maintenance.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    maintenance.imagePosition = .imageLeading
    maintenance.target = self
    maintenance.action = #selector(toggleMaintenance)
    maintenance.setAccessibilityLabel("展开词库维护")
    maintenanceContent.isHidden = true
    let disclosure = NSStackView(views: [maintenance, NSView()])
    disclosure.alignment = .centerY
    disclosure.spacing = 6
    conflictRow = SettingsForm.actions([self.conflicts])
    bindRow = SettingsForm.actions([self.bind])
    view = SettingsForm.page(title: "账号与同步", subtitle: "使用阅读达人账号，在设备之间同步收藏的单词。", contents: [
      SettingsForm.group([status, detail, SettingsForm.actions([self.login, self.logout, self.sync])]),
      conflictRow, bindRow, disclosure, maintenanceContent,
    ])
    update(userID: nil, message: "未登录 · 单词保存在本机", unassigned: 0, conflicts: 0, issue: nil)
  }

  func update(userID: String?, message: String, unassigned: Int, conflicts: Int, issue: String?) {
    status.stringValue = message
    detail.stringValue = (userID == nil ? "登录后可同步本机收藏。" : "已绑定账号 \(userID!.prefix(8))。")
      + (unassigned > 0 ? " 有 \(unassigned) 个未归属词条。" : "") + (issue.map { " \($0)" } ?? "")
    login.title = userID == nil ? "登录阅读达人…" : "切换账号…"
    logout.isHidden = userID == nil
    sync.isEnabled = userID != nil
    self.conflicts.isHidden = conflicts == 0
    conflictRow.isHidden = conflicts == 0
    bind.isHidden = userID == nil || unassigned == 0
    bindRow.isHidden = bind.isHidden
  }

  @objc private func performAccountAction(_ sender: NSButton) { actions[sender.tag]() }
  @objc private func toggleMaintenance() {
    maintenanceContent.isHidden = maintenance.state != .on
    maintenance.image = NSImage(systemSymbolName: maintenance.state == .on ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    maintenance.setAccessibilityLabel(maintenance.state == .on ? "收起词库维护" : "展开词库维护")
  }
}
