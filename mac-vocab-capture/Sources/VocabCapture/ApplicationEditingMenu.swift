import AppKit

@MainActor
enum ApplicationEditingMenu {
  static func make() -> NSMenu {
    let menu = NSMenu()
    let application = menu.addItem(withTitle: "拾词助手", action: nil, keyEquivalent: "")
    application.submenu = NSMenu(title: "拾词助手")
    application.submenu?.addItem(
      withTitle: "退出拾词助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let editing = menu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
    let commands = NSMenu(title: "编辑")
    editing.submenu = commands
    commands.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = commands.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    commands.addItem(.separator())
    commands.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    commands.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    commands.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    commands.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let viewing = menu.addItem(withTitle: "显示", action: nil, keyEquivalent: "")
    let zoom = NSMenu(title: "显示")
    viewing.submenu = zoom
    zoom.addItem(
      withTitle: "放大问答文字", action: #selector(ScreenshotQuestionPanel.zoomIn(_:)), keyEquivalent: "+"
    )
    zoom.addItem(
      withTitle: "缩小问答文字", action: #selector(ScreenshotQuestionPanel.zoomOut(_:)),
      keyEquivalent: "-")
    zoom.addItem(
      withTitle: "恢复默认大小", action: #selector(ScreenshotQuestionPanel.resetZoom(_:)),
      keyEquivalent: "0")
    // Nil targets let AppKit route and validate actions using the focused editor.
    return menu
  }
}
