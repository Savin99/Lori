import SwiftUI

/// Чип движка в нижней панели: иконка локальности, название, состояние.
/// Иконка отвечает на главный вопрос — уходит ли запись с телефона.
struct EngineChip: View {
    let engine: EngineDescriptor
    let readiness: EngineReadiness
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: engine.locality.symbol)
                    .font(LoriFont.tiny)
                Text(engine.displayName)
                    .font(LoriFont.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if readiness != .ready {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(LoriFont.tiny)
                }
                Image(systemName: "chevron.down")
                    .font(LoriFont.tiny.weight(.semibold))
                    .opacity(0.45)
            }
            .foregroundStyle(readiness == .ready ? LoriPalette.ink : LoriPalette.warn)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                readiness == .ready ? LoriPalette.panelChip : LoriPalette.warn.opacity(0.14),
                in: Capsule()
            )
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("engineChip")
        .accessibilityLabel("Движок: \(engine.displayName)")
        .accessibilityHint(readiness.badge ?? "Выбрать другой движок")
    }
}

/// Чип режима. У движка без режимов его нет вовсе — строка схлопывается.
struct ModeChip: View {
    let engine: EngineDescriptor
    let current: TranscriptionMode
    let select: (TranscriptionMode) -> Void

    var body: some View {
        Menu {
            ForEach(engine.modes) { mode in
                Button {
                    select(mode)
                } label: {
                    if mode.id == current.id {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            // Иконки у режима нет намеренно: стрелка уже говорит, что это выбор,
            // а освободившиеся точки нужны названию.
            HStack(spacing: 4) {
                Text(current.short)
                    .font(LoriFont.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(LoriFont.tiny.weight(.semibold))
                    .opacity(0.45)
            }
            .foregroundStyle(LoriPalette.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LoriPalette.panelChip, in: Capsule())
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .accessibilityIdentifier("modeChip")
        .accessibilityLabel("Режим: \(current.title)")
    }
}

/// Список движков: сначала то, что считает сам телефон, потом облако.
///
/// Один компонент на оба места — шит из панели и экран настроек. До этого их
/// было два, и они уже разошлись: имя «GigaAM v3» было записано в четырёх
/// местах по-разному, готовность в одном показывалась бейджем, в другом
/// строкой «Состояние», а новый движок требовал правок в обоих.
struct EngineSections: View {
    @ObservedObject var directory: EngineDirectory
    @Binding var selection: String
    /// Что сделать после выбора: шит закрывается, экран настроек остаётся.
    var onSelect: () -> Void = {}

    var body: some View {
        Section("На телефоне") {
            ForEach(EngineCatalog.onDevice()) { row($0) }
        }
        Section("В облаке") {
            ForEach(EngineCatalog.cloud()) { row($0) }
        }
    }

    private func row(_ engine: EngineDescriptor) -> some View {
        let readiness = directory.readiness(of: engine.kind)
        return Button {
            selection = engine.kind.rawValue
            directory.refresh()
            onSelect()
        } label: {
            HStack(spacing: 12) {
                // Иконка кодирует локальность, а не бренд: главный вопрос —
                // уходит ли запись с телефона.
                Image(systemName: engine.locality.symbol)
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.lime)
                    .frame(width: 34, height: 34)
                    .background(LoriPalette.limeSoft.opacity(0.55), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.displayName)
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                    Text(engine.subtitle)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                }

                Spacer(minLength: 8)

                // Галочка и бейдж вместе, а не или-или: выбранный движок может
                // быть не готов, и тогда «Нет ключа» вытесняло галочку — было
                // не видно, что этот движок вообще выбран.
                if let badge = readiness.badge {
                    Text(badge)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.warn)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LoriPalette.warn.opacity(0.14), in: Capsule())
                }
                if engine.kind.rawValue == selection {
                    Image(systemName: "checkmark")
                        .font(LoriFont.meta.weight(.semibold))
                        .foregroundStyle(LoriPalette.lime)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("engineRow.\(engine.id)")
    }
}

/// Шит выбора движка из нижней панели.
struct EnginePicker: View {
    @ObservedObject var directory: EngineDirectory
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                EngineSections(directory: directory, selection: $selection) { dismiss() }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(LoriPalette.canvas)
            .navigationTitle("Движок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("enginePicker")
    }
}
