import SwiftUI

struct ComposerModelPicker: View {
    @ObservedObject var model: AppModel
    @State private var presented = false
    @State private var choosingModel = false
    @State private var catalogRetry = 0

    private let modes = ChatWorkMode.allCases
    private var modelTitle: String {
        if model.useFreeModel { return model.builtinModelTitle }
        return model.hasCustomModel ? model.modelName : "Выбрать модель"
    }

    var body: some View {
        Button {
            choosingModel = false
            presented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(modelTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 132)
                    .fixedSize(horizontal: true, vertical: false)
                Text(model.selectedWorkMode.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                if presented { Capsule().fill(Color.primary.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Модель и глубина работы")
        .accessibilityValue("\(modelTitle), \(model.selectedWorkMode.title)")
        .help("Выбрать модель и глубину работы")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            if choosingModel { modelList }
            else { effortPanel }
        }
    }

    private var effortPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(model.selectedWorkMode.title, systemImage: "bolt")
                    .font(.headline)
                Spacer()
                Button {
                    model.setWorkMode(.high)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Сбросить на High")
                .help("Сбросить на High")
            }
            Button { choosingModel = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Text(modelTitle).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(8)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Выбрать модель")
            .accessibilityValue(modelTitle)

            Slider(value: Binding(
                get: { Double(modes.firstIndex(of: model.selectedWorkMode) ?? 2) },
                set: { model.setWorkMode(modes[Int($0.rounded())]) }
            ), in: 0...Double(modes.count - 1), step: 1)
            .accessibilityLabel("Глубина работы")
            .accessibilityValue(model.selectedWorkMode.title)
            HStack(spacing: 4) {
                ForEach(modes, id: \.self) { mode in
                    Button(mode.title) { model.setWorkMode(mode) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(model.selectedWorkMode == mode ? .semibold : .regular))
                        .foregroundStyle(model.selectedWorkMode == mode ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(model.selectedWorkMode == mode ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .frame(width: 336)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { choosingModel = false } label: {
                Label("Модель", systemImage: "chevron.left").font(.headline)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Назад к глубине работы")

            modelRow("Автомодель", detail: "FreeLLMAPI подбирает доступную модель",
                     selected: model.useFreeModel && model.builtinModel == "auto:fast") {
                model.selectBuiltinModel(nil)
            }
            if model.hasCustomModel {
                modelRow(model.modelName, detail: "Свой endpoint", selected: !model.useFreeModel) {
                    model.selectModel(useFree: false)
                }
            }
            if !model.gatewayModels.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.gatewayModels) { choice in
                            modelRow(choice.name, selected: model.useFreeModel && model.builtinModel == choice.id) {
                                model.selectBuiltinModel(choice)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(min(model.gatewayModels.count, 7)) * 31)
                .accessibilityLabel("Бесплатные модели")
            }
            if model.catalogLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загружаем каталог…").foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if model.catalogUnavailable {
                Button("Повторить загрузку каталога") { catalogRetry += 1 }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Divider()
            Button {
                presented = false
                model.showSettings = true
            } label: {
                Label("Настройки модели…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 336, alignment: .leading)
        .task(id: catalogRetry) { await model.loadGatewayModels() }
    }

    private func modelRow(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            presented = false
        } label: {
            ComposerOptionLabel(title: title, detail: detail, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ComposerPermissionPicker: View {
    @ObservedObject var model: AppModel
    @State private var presented = false
    @State private var confirmFullAccess = false

    var body: some View {
        Button { presented.toggle() } label: {
            Label(model.approvalMode.title, systemImage: "shield")
                .foregroundStyle(model.approvalMode == .fullAccess ? Color.orange : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background {
                    if presented { Capsule().fill(Color.primary.opacity(0.08)) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Разрешения агента")
        .accessibilityValue(model.approvalMode.title)
        .help("Разрешения агента")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Разрешения для этого чата")
                    .font(.headline)
                    .padding(.bottom, 5)
                ForEach(ChatApprovalMode.allCases, id: \.self) { mode in
                    let selected = model.approvalMode == mode
                    let needsFolder = mode == .projectEdits && model.selectedSession?.project == nil
                    Button {
                        presented = false
                        if mode == .fullAccess && !selected { confirmFullAccess = true }
                        else { model.setApprovalMode(mode) }
                    } label: {
                        ComposerOptionLabel(title: mode.title,
                                            detail: needsFolder ? "Сначала выберите папку проекта." : mode.detail,
                                            selected: selected,
                                            tint: mode == .fullAccess ? .orange : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(needsFolder || !model.canChangeProject || model.isPlanning)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if model.isPlanning {
                    Text("Сейчас включён режим плана. Агент только читает файлы.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(14)
            .frame(width: 325, alignment: .leading)
        }
        .alert("Включить полный доступ к действиям?", isPresented: $confirmFullAccess) {
            Button("Отмена", role: .cancel) {}
            Button("Включить", role: .destructive) { model.setApprovalMode(.fullAccess) }
        } message: {
            Text("Агент сможет выполнять команды и правки без подтверждения. Режим сбросится после выхода из приложения или смены папки.")
        }
    }
}

private struct ComposerOptionLabel: View {
    let title: String
    let detail: String?
    let selected: Bool
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(tint).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 29)
        .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
