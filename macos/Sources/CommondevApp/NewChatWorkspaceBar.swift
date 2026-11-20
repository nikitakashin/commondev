import SwiftUI

struct NewChatWorkspaceBar: View {
    @ObservedObject var model: AppModel
    let session: ChatSession
    @State private var repository: ChatGit?
    @State private var sourceBranch: String?

    var body: some View {
        HStack(spacing: 14) {
            folderPicker
            if let repository {
                gitMenu(repository)
            }
            Spacer(minLength: 0)
            if model.isPreparingWorktree {
                ProgressView().controlSize(.small).accessibilityLabel("Создаём worktree")
            } else if session.worktreePath != nil {
                Label(session.worktreeBranch ?? "Worktree", systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(session.worktreePath ?? "")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 15)
        .background(TideAppearance.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.08)))
        .task(id: session.projectPath) {
            repository = nil
            sourceBranch = nil
            guard let project = session.project else { return }
            let state = try? await ChatGit.inspect(project)
            guard !Task.isCancelled else { return }
            repository = state
            sourceBranch = state?.branch
        }
    }

    private var folderPicker: some View {
        Menu {
            Button(session.project == nil ? "Выбрать папку…" : "Сменить папку…", action: model.chooseProjectFolder)
            if session.project != nil {
                Button("Убрать папку") { model.setProjectFolder(nil) }
            }
        } label: {
            Label(session.project?.lastPathComponent ?? "Выбрать папку", systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .disabled(!model.canChangeProject)
        .help(session.projectPath ?? "Назначить папку проекта")
        .accessibilityLabel("Папка проекта")
        .accessibilityValue(session.project?.lastPathComponent ?? "Без папки")
    }

    private func gitMenu(_ repository: ChatGit) -> some View {
        Menu {
            if session.worktreePath != nil {
                Text("База worktree: \(session.worktreeBranch ?? "HEAD")")
            } else {
                Picker("Ветка для worktree", selection: $sourceBranch) {
                    Text("Текущий коммит (HEAD)").tag(nil as String?)
                    ForEach(repository.branches, id: \.self) { branch in
                        Text(branch).tag(Optional(branch))
                    }
                }
                .disabled(!repository.hasCommit)
                Button {
                    Task { await model.prepareWorktree(branch: sourceBranch) }
                } label: {
                    Label("Создать worktree", systemImage: "arrow.triangle.branch")
                }
                .disabled(!repository.hasCommit)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.canChangeProject)
        .accessibilityLabel("Настройки Git")
        .help(repository.branch.map { "Текущая ветка: \($0)" } ?? "Настройки Git")
    }
}
