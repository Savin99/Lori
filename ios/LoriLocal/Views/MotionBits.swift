import SwiftUI

/// Движение в чате. Выбрано владельцем по живым макетам (`design/motion/index.html`):
/// кольцо с процентами там, где прогресс настоящий; бегущий блеск там, где его нет;
/// текст, проявляющийся строками, вместо стены сразу.
///
/// Всё системными средствами SwiftUI — сторонних анимационных библиотек в проекте нет
/// и не нужно: `trim`, `phaseAnimator` и `transition` делают ровно это, а зависимость
/// ради того же движения только утяжелила бы приложение.

/// Кольцо прогресса. С долей — растёт по-настоящему и подписано процентами;
/// без доли — крутится, потому что честного числа взять негде.
struct ProgressRing: View {
    let fraction: Double?
    var size: CGFloat = 34
    var lineWidth: CGFloat = 3

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(LoriPalette.limeSoft, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(LoriPalette.lime, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.45), value: fraction)
                Text(percent(fraction))
                    .font(.system(size: size * 0.3, weight: .bold).monospacedDigit())
                    .foregroundStyle(LoriPalette.lime)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.45), value: fraction)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(LoriPalette.lime, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            }
        }
        .frame(width: size, height: size)
        .onAppear { spin = true }
        .accessibilityLabel(fraction.map { "Готово \(percent($0))" } ?? "Идёт работа")
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// Строка состояния с бегущим блеском — для работы, длину которой мы не знаем.
/// Приём снят с живых чатов: одно слово вместо спиннера с полосой.
struct ShimmerLabel: View {
    let text: String
    var font: Font = LoriFont.small

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(LoriPalette.muted)
            .overlay {
                // Блик едет по маске из того же текста: подсвечивается ровно набор,
                // а не прямоугольник вокруг него.
                GeometryReader { geometry in
                    let width = geometry.size.width
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        LinearGradient(
                            colors: [.clear, LoriPalette.ink.opacity(0.85), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(60, width * 0.55))
                        .offset(x: -width * 0.6 + (width * 1.6) * phase)
                    }
                }
                .mask(Text(text).font(font))
                .allowsHitTesting(false)
            }
            .accessibilityLabel(text)
    }
}

/// Текст, который проявляется строками — по выбранному варианту 4В: в переписке
/// видно первые строки, а читать целиком человек уходит в карточку записи.
///
/// Строки настоящие, не серые заглушки: рисовать вместо готового текста полоски
/// значило бы прятать содержимое ради красоты.
struct RevealedLines: View {
    let text: String
    var limit = 3
    var font: Font = LoriFont.meta

    @State private var shown = false

    private var lines: [String] { MotionText.firstLines(of: text, limit: limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(font)
                    .foregroundStyle(LoriPalette.ink.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(shown ? 1 : 0)
                    .offset(x: shown ? 0 : -8)
                    .animation(.easeOut(duration: 0.28).delay(Double(index) * 0.07), value: shown)
            }
        }
        .onAppear { shown = true }
    }
}

/// Разрезка текста на первые строки. Отдельно от вьюхи, чтобы проверялась тестом.
enum MotionText {
    /// Строки нарезаются по словам примерно под ширину экрана: точная верстка
    /// всё равно за `Text`, а нам нужно только не отдать одну строку на весь абзац.
    static func firstLines(of text: String, limit: Int, charactersPerLine: Int = 42) -> [String] {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !flat.isEmpty, limit > 0 else { return [] }

        var lines: [String] = []
        var current = ""
        for word in flat {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count > charactersPerLine, !current.isEmpty {
                lines.append(current)
                // Текст кончился не сам, а по лимиту строк — это должно быть видно.
                if lines.count == limit { return withEllipsis(lines) }
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty, lines.count < limit { lines.append(current) }
        return lines
    }

    private static func withEllipsis(_ lines: [String]) -> [String] {
        guard var last = lines.last else { return lines }
        while let tail = last.last, tail == "," || tail == " " || tail == "—" || tail == "-" {
            last.removeLast()
        }
        return lines.dropLast() + ["\(last)…"]
    }
}

/// Заглушка на месте текста, который ещё считается. Не крутится и не мигает:
/// её задача — показать, что список не кончился, а не привлечь внимание.
struct Skeleton: View {
    var lines: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<lines, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5)
                    .fill(LoriPalette.bubble)
                    .frame(height: 12)
                    .frame(maxWidth: index == lines - 1 ? 180 : .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 58)
        .accessibilityElement(children: .ignore)
    }
}
