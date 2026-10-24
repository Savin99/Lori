import SwiftUI
import XCTest
@testable import LoriLocal

/// Виды Live Activity записи в PNG — посмотреть глазами в светлой и тёмной теме.
///
/// Регионы островка (`DynamicIsland`) рисует только система, поэтому здесь островок
/// собран вручную по его размерам (капсула 37 pt у камеры, развёрнутый — 371 pt
/// шириной со скруглением 44): начинка та же, что в расширении (`RecordingIslandParts`),
/// а раскладка — приблизительная. Настоящий островок — снимками симулятора.
///
/// Снимки уходят вложениями прогона: `xcrun xcresulttool export attachments`.
@MainActor
final class RecordingActivitySnapshotTests: XCTestCase {
    typealias State = RecordingActivityAttributes.ContentState

    private let url = URL(string: "ru.ilyaqa.lori.local.qa://recording/finish")!

    private func state(
        _ phase: State.Phase,
        recorded: TimeInterval = 754,
        reason: String? = nil,
        canDiscard: Bool = false,
        note: String? = nil
    ) -> State {
        State(
            phase: phase,
            timerStart: Date.now.addingTimeInterval(-recorded),
            recorded: recorded,
            reason: reason,
            finishOpensApp: false,
            finishTitle: "Расшифровать",
            canDiscard: canDiscard,
            note: note
        )
    }

    func testLockScreenPresentations() throws {
        let cases: [(String, State, Bool)] = [
            ("recording", state(.recording), false),
            ("paused-call", state(.paused, reason: "звонок"), false),
            ("restored", state(.paused, reason: "приложение перезапускалось", canDiscard: true), false),
            ("stale", state(.recording), true),
            ("saving", state(.saving), false),
            ("sent", state(.finished, note: "Отправлено на расшифровку"), false),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, state, stale) in cases {
                let view = RecordingLockScreenView(state: state, finishURL: url, stale: stale)
                    .frame(width: 364)
                    .background(RecordingTint.canvas(for: scheme), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .padding(12)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.82))
                try attach(view, scheme: scheme, named: "activity-lock-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testDynamicIslandPresentations() throws {
        let cases: [(String, State)] = [
            ("recording", state(.recording)),
            ("paused-call", state(.paused, reason: "звонок")),
            ("restored", state(.paused, reason: "приложение перезапускалось", canDiscard: true)),
            ("hour", state(.recording, recorded: 3_754)),
            ("saving", state(.saving)),
        ]
        for (name, state) in cases {
            try attach(IslandMock(state: state, finishURL: url), scheme: .dark, named: "activity-island-\(name)")
        }
    }

    private func attach(_ view: some View, scheme: ColorScheme, named name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "вид \(name) не нарисовался")
        XCTAssertGreaterThan(image.size.width, 100)
        let data = try XCTUnwrap(image.pngData())
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Островок по размерам iPhone 17 Pro: свёрнутый, кружок и развёрнутый.
private struct IslandMock: View {
    let state: RecordingActivityAttributes.ContentState
    let finishURL: URL

    var body: some View {
        VStack(spacing: 18) {
            // Свёрнутый: глиф слева, таймер справа, камера посередине.
            HStack(spacing: 0) {
                RecordingIslandParts.CompactLeading(state: state)
                    .frame(width: 44, alignment: .leading)
                Spacer(minLength: 124)
                RecordingIslandParts.CompactTrailing(state: state)
            }
            .padding(.horizontal, 14)
            .frame(height: 37)
            .fixedSize()
            .background(Capsule().fill(.black))

            // Кружок, когда активностей несколько.
            RecordingIslandParts.Minimal(state: state)
                .frame(width: 37, height: 37)
                .background(Circle().fill(.black))

            // Развёрнутый.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    RecordingIslandParts.ExpandedLeading(state: state)
                    Spacer(minLength: 8)
                    RecordingIslandParts.ExpandedTrailing(state: state)
                }
                RecordingIslandParts.ExpandedBottom(state: state, finishURL: finishURL)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .frame(width: 371)
            .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
        }
        .padding(20)
        .background(Color(white: 0.85))
    }
}
