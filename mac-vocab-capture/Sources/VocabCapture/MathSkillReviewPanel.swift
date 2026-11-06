import AppKit

/// Candidate approval is an explicit human action, distinct from answer verification.
@MainActor
final class MathSkillReviewPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
  let panel: ScreenshotPanel
  private let store: MathQuestionStore
  private let onChange: () -> Void
  private let openQuestion: (String) -> Void
  private let research: (@MainActor (String, Bool, String) async throws -> Void)?
  private let projectSync: MathSkillProjectSyncCoordinator?
  private let projectStatus = NSTextField(wrappingLabelWithString: "")
  private var projectChooser: NSOpenPanel?
  private let picker = NSPopUpButton()
  private let name = NSTextField()
  private let category = NSTextField()
  private let trigger = NSTextField()
  private let exclusions = NSTextField()
  private let prerequisites = NSTextField()
  private let constraints = NSTextField()
  private let diagrams = NSTextField()
  private let permissions = MathTeachingPermissionEditor()
  private let instructions = NSTextView()
  private let summary = NSTextView()
  private var evidenceSummary = ""
  private let evidencePicker = NSPopUpButton()
  private let mergePicker = NSPopUpButton()
  private var exportChooser: NSSavePanel?
  private let boundary = NSPopUpButton()
  private let note = NSTextField()
  private let message = NSTextField(wrappingLabelWithString: "")
  private var candidates: [MathSkillCandidate] = []
  private var records: [MathQuestionRecord] = []
  private var generation = UUID()
  private var invalidated = false
  private var mutation: Task<Void, Never>?
  private var actionButtons: [NSButton] = []
  private var evidenceReview: MathSkillEvidenceReviewPanel?

  init(store: MathQuestionStore, openQuestion: @escaping (String) -> Void,
    research: (@MainActor (String, Bool, String) async throws -> Void)? = nil,
    projectSync: MathSkillProjectSyncCoordinator? = nil,
    onChange: @escaping () -> Void = {}) {
    self.store = store; self.openQuestion = openQuestion; self.research = research; self.onChange = onChange
    self.projectSync = projectSync
    panel = ScreenshotPanel(contentRect: NSRect(x:0,y:0,width:940,height:840),
      styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    super.init()
    panel.title="方法候选与教研"
    panel.minSize=NSSize(width:780,height:820)
    panel.isReleasedWhenClosed=false; panel.delegate=self
    buildContent()
  }
  func present() { guard !invalidated else { return }; refresh(); projectStatus.stringValue=projectSync?.status ?? ""; panel.center(); panel.bringToFront() }
  func prepareForLibraryRestore() async {
    evidenceReview?.invalidate(); evidenceReview=nil
    invalidated=true; generation=UUID(); exportChooser?.cancel(nil); exportChooser=nil; projectChooser?.cancel(nil); projectChooser=nil; panel.close(); mutation?.cancel(); await mutation?.value
  }
  func windowWillClose(_ notification:Notification) { generation=UUID(); exportChooser?.cancel(nil); exportChooser=nil; projectChooser?.cancel(nil); projectChooser=nil }

  private func button(_ title:String,_ selector:Selector) -> NSButton {
    let button=NSButton(title:title,target:self,action:selector); button.bezelStyle = .rounded
    button.setAccessibilityLabel(title); actionButtons.append(button); return button
  }
  private func row(_ label:String,_ field:NSTextField) -> NSStackView {
    field.placeholderString=label; field.setAccessibilityLabel(label)
    let caption=NSTextField(labelWithString:label); caption.widthAnchor.constraint(equalToConstant:86).isActive=true
    let row=NSStackView(views:[caption,field]); row.spacing=8
    field.setContentHuggingPriority(.defaultLow,for:.horizontal)
    return row
  }
  private func buildContent() {
    let explanation=NSTextField(wrappingLabelWithString:"先做人工内容审核：只看原题、答案步骤、图解和 App 展示。方法字段和教研记录是后续操作。")
    explanation.textColor = .secondaryLabelColor
    picker.target=self; picker.action=#selector(selectCandidate); picker.setAccessibilityLabel("选择待审方法候选")
    evidencePicker.setAccessibilityLabel("选择核验例题")
    mergePicker.setAccessibilityLabel("选择合并来源候选")
    mergePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
    boundary.addItems(withTitles:["适用正例","排除反例"]); boundary.setAccessibilityLabel("证据适用性")
    note.placeholderString="为何适用或应排除；不是只核对最终数字"; note.setAccessibilityLabel("教研证据说明")
    let sourceActions=NSStackView(views:[evidencePicker,boundary,button("查看原题与核验",#selector(viewQuestion)),button("确认这条依据",#selector(assess))]); sourceActions.spacing=8
    evidencePicker.setContentHuggingPriority(.defaultLow,for:.horizontal)
    instructions.setAccessibilityLabel("候选方法步骤")
    instructions.delegate = self
    for field in [name, category, trigger, exclusions, prerequisites, constraints, diagrams] { field.delegate = self }
    for control in [permissions.grade, permissions.equations, permissions.extensionPermission] {
      control.target = self; control.action = #selector(draftChanged)
    }
    summary.setAccessibilityLabel("方法证据和审校记录")
    message.textColor = .secondaryLabelColor; message.maximumNumberOfLines=3
    message.setAccessibilityLabel("候选操作说明")
    let contentReview = button("开始人工审核（原题、答案、图解）", #selector(reviewEvidencePackage))
    contentReview.controlSize = .large
    let actions=NSStackView(views:[button("刷新",#selector(refreshAction)),button("保存候选修改",#selector(save)),button("教研审校",#selector(review)),button("拒绝候选",#selector(reject)),button("批准并用于自动解题",#selector(publish))]); actions.spacing=8
    let mergeActions=NSStackView(views:[NSTextField(labelWithString:"合并来源"),mergePicker,button("合并到当前候选",#selector(merge)),button("导出技能…",#selector(exportSkill))]); mergeActions.spacing=8
    var projectViews: [NSView] = []
    if projectSync != nil {
      projectStatus.textColor = .secondaryLabelColor
      projectStatus.setAccessibilityLabel("项目技能同步状态")
      let projectActions=NSStackView(views:[button("技能项目位置…",#selector(chooseProject)),button("同步并检查项目技能",#selector(syncProject))]); projectActions.spacing=8
      projectViews=[projectStatus,projectActions]
    }
    MathEditorLayout.install(projectViews + [explanation,contentReview,picker,
      row("方法名称",name),row("题型／学段",category),row("适用条件",trigger),
      row("排除条件",exclusions),row("先修知识",prerequisites),row("限制与审校",constraints),row("图形模板",diagrams)] + permissions.views + [
      MathEditorLayout.scroll(instructions,height:100),MathEditorLayout.scroll(summary,height:80,editable:false),
      sourceActions,note,mergeActions,message,actions],in:panel)
  }
  private var selected:MathSkillCandidate? {
    guard let id = picker.selectedItem?.representedObject as? String else { return nil }
    return candidates.first { $0.id == id }
  }
  private var selectedQuestionID: String? {
    guard let id = evidencePicker.selectedItem?.representedObject as? String,
      records.contains(where: { $0.id == id }) else { return nil }
    return id
  }
  private func populate(_ picker: NSPopUpButton, entries: [(id: String, title: String)]) {
    let counts = Dictionary(grouping: entries, by: \.title).mapValues(\.count)
    var occurrences: [String: Int] = [:]
    let menu = NSMenu()
    for entry in entries {
      occurrences[entry.title, default: 0] += 1
      let suffix = counts[entry.title, default: 0] > 1 ? "（\(occurrences[entry.title]!)）" : ""
      // NSPopUpButton.addItems silently drops duplicate titles. Build actual
      // items and bind each identity before attaching the menu, never by index.
      let item = NSMenuItem(title: entry.title + suffix, action: nil, keyEquivalent: "")
      item.representedObject = entry.id
      menu.addItem(item)
    }
    picker.menu = menu
    if !entries.isEmpty { picker.selectItem(at: 0) }
  }
  private func refresh(selectID:String?=nil) {
    let revision=UUID(); generation=revision
    let previous=selectID ?? selected?.id
    Task { [weak self,store] in
      do {
        let candidates=try await store.listSkillCandidates(),records=try await store.list()
        guard let self,!self.invalidated,self.generation==revision else { return }
        self.candidates=candidates; self.records=records
        let status=["observing":"观察中","draft":"待审","published":"已发布","rejected":"已拒绝","review_required":"待复核"]
        self.populate(self.picker, entries: candidates.map { ($0.id, $0.proposal.title + " · " + (status[$0.status] ?? $0.status)) })
        if let previous, let item = self.picker.itemArray.first(where: { ($0.representedObject as? String) == previous }) {
          self.picker.select(item)
        }
        self.populate(self.evidencePicker, entries: records.map { ($0.id, $0.title) })
        self.selectCandidate()
      } catch { self?.message.stringValue=error.localizedDescription }
    }
  }
  @objc private func refreshAction() { refresh() }
  @objc private func chooseProject() {
    guard let projectSync, !invalidated, mutation == nil else { return }
    let chooser=NSOpenPanel(); projectChooser=chooser
    chooser.canChooseFiles=false; chooser.canChooseDirectories=true; chooser.allowsMultipleSelection=false
    chooser.title="选择保存 MathSkills 的项目目录"; chooser.directoryURL=projectSync.projectDirectory
    chooser.beginSheetModal(for:panel) { [weak self] result in
      guard let self else { return }; self.projectChooser=nil
      guard result == .OK, let url=chooser.url, !self.invalidated else { return }
      do { try projectSync.selectProject(url); self.syncProject() }
      catch { self.projectStatus.stringValue=error.localizedDescription }
    }
  }
  @objc private func syncProject() {
    guard let projectSync, !invalidated, mutation == nil else { return }
    projectStatus.stringValue="正在核对项目文件与方法版本…"
    mutate { _ in await projectSync.synchronize() }
  }
  @objc private func selectCandidate() {
    guard let candidate=selected else {
      message.stringValue="尚无候选。保存正常题目后，后台检查已有方法覆盖并积累重复结构。"
      for field in [name,category,trigger,exclusions,prerequisites,constraints,diagrams] { field.stringValue="" }
      instructions.string=""; evidenceSummary=""; showPublicationGaps("尚无候选；不会自动批准方法。"); return
    }
    let mergeSources=candidates.filter { $0.id != candidate.id && ["observing","draft","review_required"].contains($0.status) }
    populate(mergePicker, entries: mergeSources.map { ($0.id, $0.proposal.title) })
    mergePicker.isEnabled = !mergeSources.isEmpty && ["observing","draft","review_required"].contains(candidate.status)
    let draft=candidate.proposal
    name.stringValue=draft.title; category.stringValue=draft.category; trigger.stringValue=draft.trigger
    exclusions.stringValue=draft.exclusions; prerequisites.stringValue=draft.prerequisites
    constraints.stringValue=draft.constraints; diagrams.stringValue=draft.supportedDiagrams.joined(separator:", ")
    instructions.string=draft.instructions
    permissions.load(draft.teachingPermissions)
    let editable = !["published","rejected"].contains(candidate.status)
    for field in [name,category,trigger,exclusions,prerequisites,constraints,diagrams] { field.isEditable=editable }
    instructions.isEditable=editable
    permissions.setEnabled(editable)
    message.stringValue="版本 \(candidate.revision) · \(candidate.proposal.signature)；自动观察与人工依据分别记录。"
    evidenceSummary = ""
    showPublicationGaps("正在核对当前保存版本的发布缺口…")
    let revision=generation
    Task { [weak self,store] in
      do {
        let evidence=try await store.candidateEvidence(id:candidate.id)
        let events=try await store.candidateEvents(id:candidate.id)
        let gaps = await Self.publicationGapText(store: store, candidate: candidate)
        guard let self,self.generation==revision,self.selected?.id==candidate.id else { return }
        self.evidenceSummary=evidence.map {
          let type=$0.boundary=="applies" ? "适用正例" : $0.boundary=="excluded" ? "排除反例" : "自动观察"
          return "\(type) · 候选版本 \($0.candidateRevision) · \($0.origin == "user" ? "人工确认" : "尚未确认")\n\($0.snapshot.ocrText)\n\($0.note)"
        }.joined(separator:"\n\n")
        let decisions=["previous_revision":"修改前版本", "rejected":"拒绝", "merged":"合并来源", "merged_into":"并入其他候选"]
        if !events.isEmpty { self.evidenceSummary += "\n\n候选历史：\n" + events.map { "候选版本 \($0.revision) · \(decisions[$0.decision] ?? $0.decision)：\($0.reason)" }.joined(separator:"\n") }
        if let attempt = try? await store.candidateResearchAttempt(id: candidate.id),
          let text = try await store.candidateResearchReport(attempt: attempt),
          let report = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let research = report["review"] as? [String: Any], let checks = research["checks"] as? [[String: Any]],
          self.generation == revision, self.selected?.id == candidate.id {
          let names = ["mathematics":"数学正确性", "grade_scope":"学段限制", "conditions":"适用条件", "counterexamples":"误用反例", "diagram_grounding":"图解依据"]
          self.evidenceSummary += "\n\n当前版本教研检查（仍需人工批准）：\n" + checks.map {
            "\(names[$0["dimension"] as? String ?? ""] ?? "检查")：\($0["passed"] as? Bool == true ? "通过" : "待修改") · \($0["reason"] as? String ?? "")"
          }.joined(separator: "\n")
        }
        guard self.generation == revision, self.selected == candidate else { return }
        self.showPublicationGaps(self.editedProposal(candidate.proposal) == candidate.proposal ? gaps : Self.unsavedGapText)
      } catch { self?.message.stringValue=error.localizedDescription }
    }
  }
  private func showPublicationGaps(_ text: String) {
    summary.string = text + (evidenceSummary.isEmpty ? "" : "\n\n" + evidenceSummary)
    summary.setAccessibilityHelp("当前版本发布缺口：" + text)
  }
  private static let unsavedGapText = "存在未保存修改：下列依据只绑定已保存版本。请先保存候选修改，再重新核对依据与教研；仍需人工明确批准。"

  func controlTextDidChange(_ notification: Notification) { draftChanged() }
  func textDidChange(_ notification: Notification) { draftChanged() }
  @objc private func draftChanged() {
    guard let candidate = selected else { return }
    if editedProposal(candidate.proposal) != candidate.proposal { showPublicationGaps(Self.unsavedGapText) }
    else { refreshPublicationGaps() }
  }
  func windowDidBecomeKey(_ notification: Notification) { refreshPublicationGaps() }
  private func refreshPublicationGaps() {
    guard !invalidated, let candidate = selected else { return }
    let revision = generation
    Task { [weak self, store] in
      let text = await Self.publicationGapText(store: store, candidate: candidate)
      guard let self, !self.invalidated, self.generation == revision, self.selected == candidate else { return }
      self.showPublicationGaps(self.editedProposal(candidate.proposal) == candidate.proposal ? text : Self.unsavedGapText)
    }
  }

  /// An explanation of remaining gates, never a substitute for store publication validation.
  static func publicationGapText(store: MathQuestionStore, candidate: MathSkillCandidate, unsaved: Bool = false) async -> String {
    if unsaved { return unsavedGapText }
    do {
      guard try await store.listSkillCandidates().first(where: { $0.id == candidate.id }) == candidate else {
        return "候选保存版本已改变，请刷新后重新核对；仍需人工明确批准。"
      }
      guard candidate.status == "draft" else {
        return "保存版本 \(candidate.revision) · 当前不是待审草稿；观察记录不能作为人工批准。"
      }
      let evidence = try await store.candidateCurrentEvidence(id: candidate.id)
      let positives = evidence.filter { $0.boundary == "applies" }
      let assets = Set(positives.map(\.assetID)), texts = Set(positives.map(\.contentDigest))
      let negatives = evidence.filter { $0.boundary == "excluded" && !assets.contains($0.assetID) && !texts.contains($0.contentDigest) }
      let declarations = candidate.proposal.teachingPermissions
      var missing: [String] = []
      if declarations?.minimumGrade == nil { missing.append("最低适用年级") }
      if declarations == nil || declarations?.equationRequirement == .unknown { missing.append("方程要求") }
      if declarations == nil || declarations?.extensionRequirement == .unknown { missing.append("拓展许可") }
      let permissionText = missing.isEmpty && declarations?.isValid == true ? "教学权限：已保存三项声明，仍须人工核对。" : "教学权限待补：" + (missing.isEmpty ? "声明无效" : missing.joined(separator: "、")) + "。"
      var research = "当前版本教研：尚无与当前有效依据绑定的报告。"
      if let attempt = try? await store.candidateResearchAttempt(id: candidate.id),
        let report = try await store.candidateResearchReport(attempt: attempt),
        let object = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any] {
        let review = object["review"] as? [String: Any]
        research = object["status"] as? String == "approved" ? "当前版本教研：已记录人工批准；发布仍由题库核验全部条件。" :
          review?["recommendation"] as? String == "ready_for_human" ? "当前版本教研：AI 检查已完成，等待人工审查，尚未批准。" : "当前版本教研：需要修改或补充依据，尚未批准。"
      }
      guard try await store.listSkillCandidates().first(where: { $0.id == candidate.id }) == candidate,
        try await store.candidateCurrentEvidence(id: candidate.id) == evidence else {
        return "候选版本或原题核验依据已改变，请刷新后重新核对；仍需人工明确批准。"
      }
      return ["保存版本 \(candidate.revision) · 发布缺口（最近核对；不是发布许可）",
        "当前有效适用正例：\(positives.count)条（独立原图\(assets.count)份、独立题文\(texts.count)份；发布至少各2份）。",
        "当前有效排除反例：\(negatives.count)条（独立原图\(Set(negatives.map(\.assetID)).count)份、独立题文\(Set(negatives.map(\.contentDigest)).count)份；不与正例重复，发布至少1份）。",
        "仅统计绑定本版本且原题、最新答案及过程核验未改变的人工依据。",
        permissionText, research, "发布前仍须你核对方法、条件、步骤及学段，并明确人工批准。"].joined(separator: "\n")
    } catch { return "发布缺口暂无法核对：\(error.localizedDescription)。仍需人工明确批准。" }
  }
  private func mutate(_ action:@escaping @Sendable (MathQuestionStore) async throws -> Void) {
    guard !invalidated,mutation==nil else { return }
    let id=selected?.id; let revision=generation
    actionButtons.forEach{$0.isEnabled=false}
    mutation=Task { [weak self,store] in
      guard let self,!self.invalidated,self.generation==revision else { return }
      defer { self.mutation=nil; self.actionButtons.forEach{$0.isEnabled=true} }
      do {
        try await action(store)
        guard !self.invalidated else { return }
        self.onChange(); self.projectStatus.stringValue=self.projectSync?.status ?? ""; self.refresh(selectID:id)
      } catch {
        guard !self.invalidated,self.generation==revision else { return }
        self.message.stringValue=error.localizedDescription
      }
    }
  }
  private func editedProposal(_ saved: MathSkillProposal) -> MathSkillProposal {
    var draft=saved
    draft.title=name.stringValue; draft.category=category.stringValue; draft.instructions=instructions.string
    draft.trigger=trigger.stringValue; draft.exclusions=exclusions.stringValue; draft.prerequisites=prerequisites.stringValue; draft.constraints=constraints.stringValue
    draft.supportedDiagrams=diagrams.stringValue.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter{!$0.isEmpty}
    draft.teachingPermissions=permissions.optionalValue
    return draft
  }
  @objc private func save() {
    guard let selected else { return }; panel.makeFirstResponder(nil)
    let snapshot=editedProposal(selected.proposal)
    mutate { try await $0.editSkillCandidate(id:selected.id,proposal:snapshot) }
  }
  @objc private func reject() {
    guard let id=selected?.id else { return }
    let reason=note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else {
      message.stringValue = "请先在“审核意见”中填写拒绝原因，再点击“拒绝候选”。"
      panel.makeFirstResponder(note)
      return
    }
    mutate { try await $0.rejectSkillCandidate(id:id,note:reason) }
  }
  @objc private func merge() {
    guard let target=selected,let sourceID=mergePicker.selectedItem?.representedObject as? String else { return }
    let reason=note.stringValue
    mutate { try await $0.mergeSkillCandidates(sourceID:sourceID,targetID:target.id,note:reason) }
  }
  @objc private func exportSkill() {
    guard !invalidated,mutation==nil,exportChooser==nil,let candidate=selected else { return }
    guard candidate.status=="published" else {
      message.stringValue="请先完成教研审校与人工批准，再导出可复用技能。"; return
    }
    let chooser=NSSavePanel(); exportChooser=chooser
    chooser.title="导出已批准方法与教研依据"
    chooser.message="保存独立技能目录；包含方法原文、来源、核验记录与版本清单。"
    chooser.nameFieldStringValue="math-learned-" + candidate.id.lowercased() + "-export"
    chooser.canCreateDirectories=true
    let revision=generation
    chooser.beginSheetModal(for:panel) { [weak self] result in
      guard let self else { return }; self.exportChooser=nil
      guard result == .OK,!self.invalidated,self.generation==revision,self.selected?.id==candidate.id,
        let url=chooser.url else { return }
      self.mutate { store in
        let snapshot=try await store.candidateSkillExport(id:candidate.id)
        try Task.checkCancellation()
        try snapshot.write(to:url)
      }
    }
  }
  @objc private func publish() {
    guard let selected else { return }; panel.makeFirstResponder(nil)
    guard editedProposal(selected.proposal) == selected.proposal else {
      message.stringValue="候选内容或教学权限有未保存修改。请先点击“保存候选修改”，再核验新版本依据、教研审校并批准。"; return
    }
    guard let declaration=selected.proposal.teachingPermissions, declaration.isValid, declaration.isComplete else {
      message.stringValue="自动复用前，请核对最低适用年级、方程要求和拓展许可三项，再点击“保存候选修改”，完成新版本教研审校与人工批准。"; return
    }
    runResearch(id: selected.id, approve: true, note: note.stringValue)
  }
  @objc private func review() {
    guard let id=selected?.id else { return }
    runResearch(id: id, approve: false, note: "")
  }
  private func runResearch(id: String, approve: Bool, note: String) {
    guard let research, !invalidated, mutation == nil else {
      message.stringValue = "教研引擎尚未连接；无法批准自动复用。"; return
    }
    let revision=generation
    let candidate=selected
    actionButtons.forEach { $0.isEnabled=false }
    message.stringValue=approve ? "正在记录人工批准…" : "正在检查数学、学段、边界和图解依据…"
    mutation=Task { [weak self] in
      guard let self, !self.invalidated, self.generation==revision else { return }
      defer { self.mutation=nil; self.actionButtons.forEach { $0.isEnabled=true } }
      do {
        if approve {
          let current=try await self.store.listSkillCandidates().first { $0.id == id }
          guard current == candidate else {
            throw MathQuestionStoreError.database("候选版本已更新。请刷新并核对当前版本，再进行教研审校与人工批准。")
          }
          guard !self.invalidated, self.generation==revision else { return }
        }
        try await research(id, approve, note)
        guard !self.invalidated else { return }
        self.onChange(); self.refresh(selectID:id)
      } catch {
        guard !self.invalidated, self.generation==revision else { return }
        self.message.stringValue=error.localizedDescription
      }
    }
  }
  @objc private func reviewEvidencePackage() {
    guard let candidate = selected, !invalidated, mutation == nil else { return }
    evidenceReview?.invalidate()
    evidenceReview = MathSkillEvidenceReviewPanel(store: store, candidateID: candidate.id) { [weak self] in
      self?.onChange(); self?.refresh(selectID: candidate.id)
    }
    evidenceReview?.present()
  }
  @objc private func viewQuestion() {
    guard let id=selectedQuestionID else { return }
    panel.close(); openQuestion(id)
  }
  @objc private func assess() {
    guard let id=selected?.id,let questionID=selectedQuestionID else { return }
    let boundary=boundary.indexOfSelectedItem==0 ? "applies" : "excluded", note=note.stringValue
    mutate { store in
      let snapshot=try await store.learningSnapshot(questionID:questionID)
      guard let solution=snapshot.solutions.first(where:{$0.verificationStatus=="confirmed"}),
        let review=snapshot.reviews.last(where:{$0.solutionID==solution.id}),review.scope=="答案及解题过程" else {
        throw MathQuestionStoreError.database("请先在原题中核验答案及解题过程")
      }
      try await store.assessSkillCandidate(id:id,questionID:questionID,solutionID:solution.id,reviewID:review.id,referenceID:review.referenceID,boundary:boundary,note:note)
    }
  }
}
