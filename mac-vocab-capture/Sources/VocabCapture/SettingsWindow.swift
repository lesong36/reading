import AppKit

@MainActor
enum SettingsSection: Int, CaseIterable {
  case capture, dictionary, question, search, account

  var title: String {
    switch self {
    case .capture: "取词与快捷键"
    case .dictionary: "取词释义"
    case .question: "截图问答"
    case .search: "联网检索"
    case .account: "账号与同步"
    }
  }

  var symbol: String {
    switch self {
    case .capture: "keyboard"
    case .dictionary: "character.book.closed"
    case .question: "bubble.left.and.bubble.right"
    case .search: "globe"
    case .account: "person.crop.circle"
    }
  }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
  let panel = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
  private let navigation = NSTableView()
  private let scroll = NSScrollView()
  private let makePage: (SettingsSection) -> NSView
  private let onSelection: (SettingsSection) -> Void
  private let onClose: () -> Void
  private let onKeyChange: (Bool) -> Void
  private var pages: [SettingsSection: NSView] = [:]
  private(set) var selectedSection: SettingsSection = .capture
  private var hasSelection = false

  init(makePage: @escaping (SettingsSection) -> NSView,
    onSelection: @escaping (SettingsSection) -> Void = { _ in },
    onClose: @escaping () -> Void = {}, onKeyChange: @escaping (Bool) -> Void = { _ in }) {
    self.makePage = makePage
    self.onSelection = onSelection
    self.onClose = onClose
    self.onKeyChange = onKeyChange
    super.init()
    panel.title = "拾词助手设置"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.minSize = NSSize(width: 780, height: 540)
    panel.delegate = self
    buildContent()
    panel.center()
  }

  func show(section: SettingsSection) {
    select(section)
    panel.bringToFront()
  }

  func select(_ section: SettingsSection) {
    if !hasSelection || selectedSection != section {
      selectedSection = section
      hasSelection = true
      // End a shortcut recording session before attaching another page.
      panel.makeFirstResponder(nil)
      onSelection(section)
      let page = pages[section] ?? makePage(section)
      pages[section] = page
      let document = FlippedSettingsView()
      document.translatesAutoresizingMaskIntoConstraints = false
      scroll.documentView = document
      page.translatesAutoresizingMaskIntoConstraints = false
      document.addSubview(page)
      NSLayoutConstraint.activate([
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        page.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
        page.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
        page.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
        page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -26),
      ])
      panel.title = "\(section.title) — 拾词助手设置"
    }
    navigation.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
  }

  func windowWillClose(_ notification: Notification) { onClose() }
  func windowDidBecomeKey(_ notification: Notification) { onKeyChange(true) }
  func windowDidResignKey(_ notification: Notification) { onKeyChange(false) }
  func numberOfRows(in tableView: NSTableView) -> Int { SettingsSection.allCases.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let section = SettingsSection(rawValue: row) else { return nil }
    let cell = NSTableCellView()
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
    icon.contentTintColor = .secondaryLabelColor
    let label = NSTextField(labelWithString: section.title)
    label.font = .systemFont(ofSize: 13)
    for view in [icon, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(view)
    }
    cell.textField = label
    cell.imageView = icon
    cell.setAccessibilityLabel(section.title)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
      label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let section = SettingsSection(rawValue: navigation.selectedRow) else { return }
    select(section)
  }

  private func buildContent() {
    let root = panel.contentView!
    let sidebar = NSVisualEffectView()
    sidebar.material = .sidebar
    sidebar.blendingMode = .withinWindow
    let identity = NSTextField(labelWithString: "拾词助手")
    identity.font = .systemFont(ofSize: 16, weight: .semibold)
    let caption = NSTextField(labelWithString: "设置")
    caption.font = .systemFont(ofSize: 12)
    caption.textColor = .secondaryLabelColor
    let heading = NSStackView(views: [identity, caption])
    heading.orientation = .vertical
    heading.alignment = .leading
    heading.spacing = 5
    let sideScroll = NSScrollView()
    sideScroll.drawsBackground = false
    sideScroll.hasVerticalScroller = false
    navigation.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings")))
    navigation.headerView = nil
    navigation.style = .sourceList
    navigation.rowHeight = 40
    navigation.backgroundColor = .clear
    navigation.intercellSpacing = NSSize(width: 0, height: 4)
    navigation.dataSource = self
    navigation.delegate = self
    navigation.setAccessibilityLabel("设置分类")
    sideScroll.documentView = navigation
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let footer = NSTextField(labelWithString: version.isEmpty ? "查词与截图问答" : "版本 \(version)")
    footer.font = .systemFont(ofSize: 11)
    footer.textColor = .tertiaryLabelColor
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let divider = NSBox()
    divider.boxType = .separator
    for view in [sidebar, scroll, divider] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    for view in [heading, sideScroll, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      sidebar.addSubview(view)
    }
    NSLayoutConstraint.activate([
      sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      sidebar.widthAnchor.constraint(equalToConstant: 188),
      heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 22),
      heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26),
      sideScroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22),
      sideScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
      sideScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
      sideScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
      footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
      divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
      divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: root.topAnchor),
      divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }
}

private final class FlippedSettingsView: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
enum SettingsForm {
  static func label(_ text: String, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: secondary ? 12 : 13)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  static func page(title: String, subtitle: String, contents: [NSView]) -> NSView {
    let heading = label(title)
    heading.font = .systemFont(ofSize: 22, weight: .semibold)
    let header = column([heading, label(subtitle, secondary: true)], spacing: 6)
    let stack = column([header] + contents, spacing: 16)
    return stack
  }

  static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }

  static func row(_ title: String, control: NSView) -> NSView {
    let label = label(title)
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 16
    label.widthAnchor.constraint(equalToConstant: 104).isActive = true
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if control is NSTextField { control.heightAnchor.constraint(equalToConstant: 26).isActive = true }
    return row
  }

  static func group(_ views: [NSView]) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.borderWidth = 0.5
    box.borderColor = .separatorColor
    box.isTransparent = false
    box.fillColor = .controlBackgroundColor
    box.cornerRadius = 10
    box.contentViewMargins = .zero
    let stack = column(views)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = box.contentView!
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
    ])
    return box
  }

  static func actions(_ buttons: [NSButton]) -> NSView {
    buttons.forEach { $0.bezelStyle = .rounded }
    let stack = NSStackView(views: [NSView()] + buttons)
    stack.spacing = 8
    return stack
  }
}
