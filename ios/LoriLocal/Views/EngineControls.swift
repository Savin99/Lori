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

/// Какие движки предлагать в быстром выборе — в шите из панели и в подменю
/// «Расшифровать заново» на экране записи.
///
/// Владелец, 6 октября 2026: «в селекторе не нужно показывать модели, которых
/// нет». Быстрый выбор — про то, чем можно расшифровать прямо сейчас: строка
/// с бейджем «Нет ключа» обещала движок, который тут же остановится. Полный
/// список с бейджами живёт в «Настройки → Движок» — там модель качают и ключ
/// вводят, и его не фильтруем. Своей проверки готовности здесь нет: множество
/// готовых даёт `EngineDirectory`, тот же, что рисует бейдж на чипе.
enum EngineShortlist {
    /// Раздел списка: «На телефоне» или «В облаке».
    struct Group: Identifiable {
        let title: String
        let engines: [EngineDescriptor]

        var id: String { title }
    }

    /// Готовые движки в порядке каталога — и выбранный, даже неготовый.
    ///
    /// Выбранный не прячется: пропади он из шита, выглядело бы, будто движок
    /// подменился сам, а этого контракт не допускает («The engine is never
    /// substituted silently»). Он остаётся со своим бейджем и галочкой.
    static func engines(
        _ engines: [EngineDescriptor],
        ready: Set<TranscriptionEngineKind>,
        keeping selected: TranscriptionEngineKind?
    ) -> [EngineDescriptor] {
        engines.filter { ready.contains($0.kind) || $0.kind == selected }
    }

    /// Разделы списка. `onlyReady == false` — экран настроек: все движки, оба
    /// раздела. В коротком списке пустой раздел не показывается вовсе: заголовок
    /// «В облаке» без единой строки под ним — пустое обещание.
    static func groups(
        onlyReady: Bool,
        ready: Set<TranscriptionEngineKind>,
        keeping selected: TranscriptionEngineKind?
    ) -> [Group] {
        let all = [
            Group(title: "На телефоне", engines: EngineCatalog.onDevice()),
            Group(title: "В облаке", engines: EngineCatalog.cloud()),
        ]
        guard onlyReady else { return all }
        return all
            .map { Group(title: $0.title, engines: engines($0.engines, ready: ready, keeping: selected)) }
            .filter { !$0.engines.isEmpty }
    }

    /// Подпись строки в конце шита. Спрятано хоть что-то — она говорит, где
    /// остальное; готовы все — просто ведёт в настройки движков: «Другие движки»
    /// при полном списке обещали бы то, чего нет.
    static func settingsTitle(
        ready: Set<TranscriptionEngineKind>,
        keeping selected: TranscriptionEngineKind?
    ) -> String {
        let shown = engines(EngineCatalog.all, ready: ready, keeping: selected).count
        return shown < EngineCatalog.all.count ? "Другие движки — в настройках" : "Настройки движков"
    }
}

extension EngineDirectory {
    /// Движки, готовые к работе прямо сейчас, — по тем же признакам, что бейдж
    /// чипа: есть ключ, лежит модель.
    var readyKinds: Set<TranscriptionEngineKind> {
        Set(TranscriptionEngineKind.allCases.filter { readiness(of: $0) == .ready })
    }

    /// Готовность для экранов: чип и шит панели, подменю «Расшифровать заново».
    /// С проверочным движком QA считает он, и любой выбор честно готов — иначе
    /// снимки показывали бы «Нет ключа», а быстрый выбор прятал бы движки,
    /// которыми заглушка на деле считает.
    static func forInterface() -> EngineDirectory {
        #if DEBUG
        if QAStubEngine.enabled {
            return EngineDirectory(hasKey: { _ in true }, hasModel: { _ in true }, hasWhisperModel: { true })
        }
        #endif
        return EngineDirectory()
    }
}

/// Список движков: сначала то, что считает сам телефон, потом облако.
///
/// Один компонент на оба места — шит из панели и экран настроек. До этого их
/// было два, и они уже разошлись: имя «GigaAM v3» было записано в четырёх
/// местах по-разному, готовность в одном показывалась бейджем, в другом
/// строкой «Состояние», а новый движок требовал правок в обоих. Разница между
/// местами одна — `onlyReady`: шит показывает только готовые движки и выбранный,
/// экран настроек — все (`EngineShortlist`).
struct EngineSections: View {
    @ObservedObject var directory: EngineDirectory
    @Binding var selection: String
    /// Только готовые движки и выбранный — для шита из панели.
    var onlyReady = false
    /// Что сделать после выбора: шит закрывается, экран настроек остаётся.
    var onSelect: () -> Void = {}

    var body: some View {
        ForEach(EngineShortlist.groups(onlyReady: onlyReady, ready: directory.readyKinds, keeping: selected)) { group in
            Section(group.title) {
                ForEach(group.engines) { row($0) }
            }
        }
    }

    /// Выбранный движок — так же, как его читает чип панели: незнакомая строка
    /// в настройках означает GigaAM.
    private var selected: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: selection) ?? .gigaam
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
                        // Место — сначала пилюле: рядом с галочкой «Скачать модель»
                        // ломалась на две строки внутри капсулы. Переносится подпись
                        // движка слева, а пилюля — только когда места нет совсем
                        // (крупный шрифт): `fixedSize` там вытолкнул бы строку за край.
                        .layoutPriority(1)
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

/// Шит выбора движка из нижней панели: только то, чем можно расшифровать прямо
/// сейчас, плюс выбранный движок (`EngineShortlist`). Остальное — одной тихой
/// строкой в конце: она открывает тот же экран, что «Настройки → Движок», где
/// модель качают и ключ вводят.
struct EnginePicker: View {
    @ObservedObject var directory: EngineDirectory
    @Binding var selection: String
    /// Нужен экрану движка, который открывает строка в настройки. Без подписки:
    /// сервис публикует ход расшифровки, и шит перерисовывался бы на каждом тике.
    let transcription: TranscriptionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                EngineSections(directory: directory, selection: $selection, onlyReady: true) { dismiss() }
                Section {
                    NavigationLink {
                        EngineScreen(transcription: transcription)
                    } label: {
                        // Тихо, без акцента: это выход к остальному, а не выбор.
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .font(LoriFont.meta)
                                .foregroundStyle(LoriPalette.muted)
                                .frame(width: 34)
                            Text(EngineShortlist.settingsTitle(
                                ready: directory.readyKinds,
                                keeping: TranscriptionEngineKind(rawValue: selection) ?? .gigaam
                            ))
                            .font(LoriFont.meta)
                            .foregroundStyle(LoriPalette.muted)
                        }
                    }
                    .accessibilityIdentifier("engineSettingsLink")
                }
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
            // Готовность перечитывается при каждом показе — и при возврате с экрана
            // движка: там могли скачать модель или ввести ключ, а у экрана свой
            // справочник. Признаки дешёвые: наличие ключа и папки модели.
            .onAppear { directory.refresh() }
        }
        .accessibilityIdentifier("enginePicker")
    }
}
