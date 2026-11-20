import AppKit
import AgentCore
import SwiftUI

private func projectImage(_ name: String) -> Image {
    guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
          let image = NSImage(contentsOf: url) else { return Image(systemName: "photo") }
    return Image(nsImage: image)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var scheme
    @State private var showHarnessInfo = false
    @State private var confirmQueueRoute = false
    @State private var showAddMenu = false
    @State private var hoveredProject: String?
    @State private var hoveredChat: UUID?
    @State private var chatToRename: ChatSession?
    @State private var chatToDelete: ChatSession?
    @AppStorage("sidebarWidth") private var sidebarWidth = 232.0
    @AppStorage("dictationLanguage") private var dictationLanguage = "ru-RU"
    @State private var resizeOrigin: CGFloat?
    @StateObject private var dictation = Dictation()

    var body: some View {
        GeometryReader { bounds in
            let maximum = min(300, max(192, bounds.size.width - 575))
            let width = min(max(sidebarWidth, 192), maximum)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background { TideSidebarSurface() }
                    .overlay(alignment: .trailing) { resizeHandle(width: width, maximum: maximum) }
                VStack(spacing: 0) {
                    if let session = model.selectedSession {
                        header
                        transcript(session)
                            .frame(maxHeight: .infinity)
                    } else {
                        emptyState
                    }
                }
                .frame(minWidth: 555, maxWidth: .infinity, maxHeight: .infinity)
                .background(TideAppearance.canvas)
            }
        }
        .coordinateSpace(name: "workspaceLayout")
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.selectedID) { _ in dictation.cancel() }
        .onDisappear { dictation.cancel() }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model, harness: model.harness, showHarnessInfo: $showHarnessInfo)
        }
        .sheet(item: $chatToRename) { chat in
            ChatRenameSheet(name: chat.displayName) { model.renameChat(chat.id, to: $0) }
        }
        .confirmationDialog("Удалить чат?", isPresented: Binding(
            get: { chatToDelete != nil },
            set: { if !$0 { chatToDelete = nil } }
        ), titleVisibility: .visible, presenting: chatToDelete) { chat in
            Button("Удалить", role: .destructive) { model.deleteChat(chat.id) }
            Button("Отмена", role: .cancel) {}
        } message: { chat in
            Text("Переписка «\(chat.displayName)» будет удалена.")
        }
        .alert("commondev", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("Хорошо") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func resizeHandle(width: CGFloat, maximum: CGFloat) -> some View {
        Color.clear.frame(width: 6)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("workspaceLayout"))
                .onChanged { drag in
                    let start = resizeOrigin ?? width
                    resizeOrigin = start
                    sidebarWidth = min(max(192, start + drag.translation.width), maximum)
                }
                .onEnded { _ in resizeOrigin = nil })
            .accessibilityElement()
            .accessibilityLabel("Ширина панели сессий")
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                sidebarWidth = min(max(192, width + (direction == .increment ? 12 : -12)), maximum)
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TideMark(size: 33)
                Text("commondev").font(.system(size: 22, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 57)
            .padding(.bottom, 29)

            Button(action: model.newChat) {
                Label("Новый чат", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tideActionStyle()
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isRunning || model.isPreparingWorktree)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            ScrollView {
                let groups = Dictionary(grouping: model.sessions, by: \.projectPath)
                let pinned = model.sessions.filter { $0.pinned == true }
                LazyVStack(alignment: .leading, spacing: 15) {
                    if !pinned.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(pinned) { sessionRow($0, compact: true) }
                            }
                        }
                        .accessibilityLabel("Закреплённые чаты")
                    }
                    ForEach(groups.keys.sorted { ($0 ?? "") < ($1 ?? "") }, id: \.self) { path in
                        let chats = (groups[path] ?? []).filter { $0.pinned != true }
                        if path != nil || !chats.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                projectHeading(path)
                                ForEach(chats) { sessionRow($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .disabled(model.isRunning || model.isPreparingWorktree)
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)

            HStack(spacing: 12) {
                Button { model.showSettings = true } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                .tideActionStyle()
                Spacer()
                let themeLabel = scheme == .dark ? "Включить светлую тему" : "Включить тёмную тему"
                Button {
                    appearance = scheme == .dark ? "light" : "dark"
                } label: {
                    projectImage(scheme == .dark ? "theme_light" : "theme_dark")
                        .resizable().scaledToFit().frame(width: 28, height: 28)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(themeLabel)
                .accessibilityLabel(themeLabel)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
    }

    private func projectHeading(_ path: String?) -> some View {
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Без папки"
        let hovered = path != nil && hoveredProject == path
        return HStack(spacing: 4) {
            Label(name, systemImage: path == nil ? "globe" : "folder")
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 2)
            if let path {
                Button { model.newChat(inProject: path) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Новый чат в «\(name)»")
                .accessibilityLabel("Новый чат в «\(name)»")
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
                .accessibilityHidden(!hovered)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .contentShape(Rectangle())
        .onHover { pointed in
            if pointed { hoveredProject = path }
            else if hoveredProject == path { hoveredProject = nil }
        }
        .help(path ?? "Глобальные чаты")
        .contextMenu {
            if let path {
                Button("Новый чат в проекте") { model.newChat(inProject: path) }
            }
        }
    }

    private func sessionRow(_ session: ChatSession, compact: Bool = false) -> some View {
        let selected = session.id == model.selectedID
        let pinTitle = session.pinned == true ? "Открепить чат" : "Закрепить чат"
        let hovered = hoveredChat == session.id
        return HStack(spacing: 0) {
            Button { model.selectSession(session.id) } label: {
                Text(session.displayName)
                    .font((compact ? Font.caption : .subheadline).weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: compact ? 115 : .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.displayName)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { model.togglePin(session.id) } label: {
                Image(systemName: session.pinned == true ? "pin.slash" : "pin")
                    .font(.caption)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(pinTitle)
            .accessibilityLabel(pinTitle)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
            .accessibilityHidden(!hovered)
        }
        .padding(.trailing, 3)
        .background {
            if compact || selected {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(selected && scheme == .dark ? 0.12 : 0.08))
            }
        }
        .contentShape(Rectangle())
        .onHover { pointed in
            if pointed { hoveredChat = session.id }
            else if hoveredChat == session.id { hoveredChat = nil }
        }
        .contextMenu {
            Button("Переименовать…") { chatToRename = session }
            Button(pinTitle) { model.togglePin(session.id) }
            Divider()
            Button("Удалить…", role: .destructive) { chatToDelete = session }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let project = model.selectedSession?.project {
                Label(project.lastPathComponent, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(project.path)
            }
            Text(model.selectedSession?.displayName ?? ChatTitle.placeholder)
                .font(.system(size: 32, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 32)
        .padding(.bottom, 10)
    }

    private var addMenu: some View {
        let project = model.selectedSession?.project
        return Button { showAddMenu.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .background {
                    if showAddMenu { Circle().fill(Color.primary.opacity(0.08)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Добавить файлы, назначить папку или выбрать режим плана")
        .accessibilityLabel("Добавить")
        .popover(isPresented: $showAddMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Добавить").font(.headline).padding(.bottom, 5)
                addOption("Прикрепить файлы…", icon: "paperclip", action: model.chooseAttachments)
                    .disabled(model.draftAttachments.count >= ChatAttachment.maxCount)
                addOption(project == nil ? "Выбрать папку проекта…" : "Сменить папку проекта…",
                          icon: "folder", action: model.chooseProjectFolder)
                    .disabled(!model.canChangeProject)
                if project != nil {
                    addOption("Убрать папку проекта", icon: "folder.badge.minus") { model.setProjectFolder(nil) }
                        .disabled(!model.canChangeProject)
                }
                Divider()
                addOption(model.isPlanning ? "Выключить режим плана" : "Включить режим плана",
                          icon: "list.bullet.rectangle") { model.setPlanMode(!model.isPlanning) }
                    .disabled(!model.canChangeProject)
            }
            .padding(14)
            .frame(width: 265, alignment: .leading)
        }
    }

    private func addOption(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showAddMenu = false
            action()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Button("Новый чат", action: model.newChat)
                .tideActionStyle(prominent: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcript(_ session: ChatSession) -> some View {
        let rows = TranscriptRow.rows(for: session.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Что нужно сделать?").font(.title2.weight(.semibold))
                        }
                        .padding(.top, 35)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case let .message(message):
                            MessageView(message: message, workingStatus: message.id == model.activeUserMessageID
                                        ? (model.approval != nil ? "Жду разрешения" : model.status.isEmpty ? "Работаю" : model.status)
                                        : nil)
                        case let .activity(_, userID, entries):
                            ActivityDisclosure(entries: entries, agents: model.agents.filter {
                                $0.sessionID == session.id && $0.userMessageID == userID
                            }, stopAgent: model.stopAgent)
                        }
                    }
                    if let request = model.approval {
                        ApprovalCard(request: request) { allowed in
                            guard model.approval?.id == request.id else { return }
                            model.resolveApproval(allowed)
                        }
                        .id(request.id)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .onChange(of: model.approval?.id) { id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: rows.last?.id) { id in
                if let id, model.approval == nil { proxy.scrollTo(id, anchor: .bottom) }
            }
            .task(id: session.id) {
                if let id = rows.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: -10) {
            if let session = model.selectedSession, session.messages.isEmpty {
                NewChatWorkspaceBar(model: model, session: session)
                    .id(session.id)
                    .padding(.horizontal, 16)
            }
            composerInput.zIndex(1)
        }
        .frame(maxWidth: 900)
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Сообщение агенту…").foregroundStyle(.secondary)
                        .padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerEditor(text: $model.draft, editable: dictation.state == .idle, submit: sendDraft)
                    .id(model.selectedID)
                    .frame(height: 36)
            }
            if !model.draftAttachments.isEmpty {
                attachmentChips
            }
            HStack(spacing: 9) {
                addMenu
                ComposerPermissionPicker(model: model)
                if model.isPlanning {
                    Button {
                        model.setPlanMode(false)
                    } label: {
                        Label("План", systemImage: "list.bullet.rectangle")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!model.canChangeProject)
                    .help("Выйти из режима плана")
                    .accessibilityLabel("Выйти из режима плана")
                }
                Spacer(minLength: 12)
                ComposerModelPicker(model: model)
                dictationButton
                sendButton
            }
            if (model.isRunning && hasDraftText) || (!model.isRunning && model.hasQueuedMessages) {
                HStack {
                    Spacer()
                    if model.isRunning {
                        Button("Остановить", action: model.stop)
                            .keyboardShortcut(.cancelAction)
                    } else if model.hasQueuedMessages {
                        if model.draft.isEmpty && model.draftAttachments.isEmpty {
                            Button("Вернуть в черновик", action: model.restoreFirstQueuedDraft)
                        }
                        if model.queueNeedsConnectionChoice {
                            Button("Выбрать подключение для очереди") { confirmQueueRoute = true }
                                .confirmationDialog("Отправить первое сообщение очереди и историю проекта через \(model.connectionLabel)?",
                                                    isPresented: $confirmQueueRoute, titleVisibility: .visible) {
                                    Button("Отправить через выбранное подключение", action: model.sendFirstQueuedMessage)
                                    Button("Оставить в очереди", role: .cancel) {}
                                }
                        } else {
                            Button("Продолжить очередь", action: model.resumeQueue)
                        }
                    }
                }
            }
        }
        .padding(13)
        .modifier(TideComposerGlass())
        .background {
            if model.selectedSession?.messages.isEmpty == true {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(TideAppearance.canvas)
            }
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.draftAttachments) { attachment in
                    HStack(spacing: 6) {
                        Label(attachment.name, systemImage: "doc.text").lineLimit(1)
                        Button { model.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Убрать \(attachment.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.075), in: Capsule())
                }
            }
        }
    }

    private var dictationButton: some View {
        let active = dictation.state != .idle
        let title = active ? "Остановить диктовку" : "Начать диктовку"
        return Button {
            switch dictation.state {
            case .recording: dictation.finish()
            case .requestingAccess: dictation.cancel()
            case .finishing: break
            case .idle:
                let sessionID = model.selectedID
                let prefix = model.draft
                let separator = prefix.isEmpty || prefix.last?.isWhitespace == true ? "" : " "
                dictation.start(language: dictationLanguage) { text in
                    guard model.selectedID == sessionID else { return }
                    model.draft = prefix + separator + text
                } onError: { message in
                    model.error = message
                }
            }
        } label: {
            Image(systemName: active ? "stop.fill" : "mic")
                .frame(width: 34, height: 34)
                .background(active ? Color.red.opacity(0.2) : Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .finishing)
        .accessibilityLabel(title)
        .help(title)
    }

    private var hasDraftText: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        guard dictation.state == .idle else { return }
        model.send()
    }

    private var sendButton: some View {
        let stopsRun = model.isRunning && !hasDraftText
        let disabled = model.isPreparingWorktree || (!stopsRun && (!hasDraftText || dictation.state != .idle))
        let queued = model.isRunning || model.hasQueuedMessages
        let title = stopsRun ? "Остановить" : (queued ? "В очередь" : "Отправить")
        return Button(action: stopsRun ? model.stop : sendDraft) {
            Image(systemName: stopsRun ? "stop.fill" : (queued ? "text.badge.plus" : "arrow.up"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(disabled ? Color.secondary : Color.white)
                .frame(width: 34, height: 34)
                .background(disabled ? Color.primary.opacity(0.08) : Color.accentColor, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(stopsRun ? "Остановить (Esc)" : "\(title) (Enter). Новая строка — Shift-Enter.")
        .disabled(disabled)
        .keyboardShortcut(stopsRun ? .escape : .return, modifiers: stopsRun ? [] : .command)
    }


}

struct MessageView: View {
    let message: ChatMessage
    let workingStatus: String?
    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top, spacing: 12) {
                if let workingStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(workingStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: 165, alignment: .leading)
                    .padding(.top, 9)
                    .help(workingStatus)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if message.queued == true { Text("В очереди").font(.caption).foregroundStyle(.secondary) }
                    if let attachments = message.attachments, !attachments.isEmpty {
                        Label(attachments.map(\.name).joined(separator: ", "), systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(message.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Вы. " + message.text)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if message.role == "assistant" { TideMark(size: 23) }
                    else { Image(systemName: "info.circle") }
                    Text(message.role == "assistant" ? "commondev" : "Состояние").font(.subheadline.weight(.semibold))
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ApprovalCard: View {
    let request: PendingApproval
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(request.title, systemImage: request.isEdit ? "doc.text" : "terminal")
                .font(.headline).textSelection(.enabled).padding(.horizontal, 14).padding(.top, 12)
            Text(request.location).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).padding(.horizontal, 14).padding(.bottom, 10)
            ScrollView {
                Text(request.formattedDetail)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .frame(height: min(180, CGFloat(request.bodyText.components(separatedBy: "\n").count) * 17 + 26))
            .background(Color.primary.opacity(0.045))
            HStack {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary)
                Text(request.isEdit ? "Разрешить правку файла?" : "Разрешить команду?").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Отклонить") { resolve(false) }.tideActionStyle()
                Button("Разрешить") { resolve(true) }.tideActionStyle(prominent: true)
            }
            .padding(12)
        }
        .background(TideAppearance.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.09)))
    }
}

private struct ChatRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String
    let save: (String) -> Void

    init(name: String, save: @escaping (String) -> Void) {
        _name = State(initialValue: name)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переименовать чат").font(.headline)
            TextField("Название чата", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    save(name)
                    dismiss()
                }
                .tideActionStyle(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task { focused = true }
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var harness: HarnessSupport
    @Binding var showHarnessInfo: Bool
    @State private var draft: ModelSettingsDraft
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("dictationLanguage") private var dictationLanguage = "ru-RU"
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel, harness: HarnessSupport, showHarnessInfo: Binding<Bool>) {
        self.model = model
        self.harness = harness
        self._showHarnessInfo = showHarnessInfo
        self._draft = State(initialValue: model.modelSettingsDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Настройки").font(.title2.weight(.semibold))
                Spacer()
                projectImage(scheme == .dark ? "lang_dark" : "lang_light")
                    .resizable().scaledToFit().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Русский").font(.caption).foregroundStyle(.secondary)
            }
            Form {
                Section("Модель") {
                    Picker("Провайдер", selection: $draft.useFreeModel) {
                        Text("Авто · бесплатные модели").tag(true)
                        Text("Свой endpoint").tag(false)
                    }
                    if !draft.useFreeModel {
                        TextField("URL chat completions", text: $draft.endpoint)
                            .textFieldStyle(.roundedBorder)
                        TextField("Название модели", text: $draft.modelName)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API-ключ, если нужен", text: $draft.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Модель поддерживает reasoning_effort", isOn: $draft.supportsReasoningEffort)
                        Text("Включите, если провайдер поддерживает значения low, medium и high. Для XHigh передаётся high.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Например, http://localhost:11434/v1/chat/completions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Ввод") {
                    Picker("Язык диктовки", selection: $dictationLanguage) {
                        Text("Русский").tag("ru-RU")
                        Text("English").tag("en-US")
                    }
                }
                Section("Режимы агента") {
                    HStack {
                        Text("Harness²")
                        Button { showHarnessInfo = true } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("О Harness²")
                        Spacer()
                        Toggle("Harness²", isOn: Binding(get: { harness.enabled }, set: { harness.setEnabled($0) }))
                            .labelsHidden()
                            .disabled(model.selectedSession?.project == nil)
                    }
                    if model.selectedSession?.project == nil {
                        Text("Harness² доступен в чате с папкой проекта.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if harness.enabled {
                        if !harness.status.isEmpty {
                            Text(harness.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Оформление") {
                    Picker("Тема", selection: $appearance) {
                        Text("Системная").tag("system")
                        Text("Светлая").tag("light")
                        Text("Тёмная").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    TideAccentPicker()
                    Text("Применяется сразу.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Закрыть") { model.showSettings = false }
                Button("Сохранить") { model.saveSettings(draft) }.tideActionStyle(prominent: true)
            }
        }
        .padding(24)
        .frame(width: 590, height: 630)
        .sheet(isPresented: $showHarnessInfo) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Что такое Harness²?").font(.title2.weight(.semibold))
                Text("С Harness² агент пробует разные инструкции и навыки на копиях задач. Если новый подход помогает, агент применяет его в следующих задачах. Например, так он может найти более быстрый способ обнаружить причину ошибки сборки.")
                Text("Проверки требуют дополнительных запросов к модели. Если выключить Harness², проверки остановятся и агент вернётся к стандартным инструкциям и навыкам.")
                HStack {
                    Spacer()
                    Button("Закрыть") { showHarnessInfo = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24).frame(width: 500)
        }
    }

}
