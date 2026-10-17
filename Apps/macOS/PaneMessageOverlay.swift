import SwiftUI
import XTermXKit

struct PaneMessageOverlay: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.appearance.messageLines, !model.messageFlow.pulses.isEmpty {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: reduceMotion ? 0.2 : 1 / 30)) { timeline in
                    Canvas { context, _ in
                        let frames = workspace.layout.frames(in: CGRect(origin: .zero, size: geometry.size), fractions: model.fractions)
                        let color = (model.appearance.messageColor ?? theme.chrome.activity).color
                        for pulse in model.messageFlow.pulses {
                            guard let progress = pulse.progress(now: timeline.date), let source = frames[pulse.from], let target = frames[pulse.to] else { continue }
                            let from = CGPoint(x: source.midX, y: source.midY), to = CGPoint(x: target.midX, y: target.midY)
                            var path = Path()
                            path.move(to: from)
                            if model.appearance.curvedMessages {
                                let middle = (from.x + to.x) / 2
                                path.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
                            } else { path.addLine(to: to) }
                            context.stroke(path, with: .color(color.opacity(reduceMotion ? 0.7 : 0.3)),
                                           style: StrokeStyle(lineWidth: model.appearance.lineWidth, lineCap: .round, dash: model.appearance.messagePattern.dash))
                            if !reduceMotion {
                                context.stroke(path.trimmedPath(from: max(0, progress - 0.22), to: progress), with: .color(color),
                                               style: StrokeStyle(lineWidth: model.appearance.lineWidth + 1, lineCap: .round))
                                let point = PaneMessageFlow.point(from: from, to: to, progress: progress, curved: model.appearance.curvedMessages)
                                context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(color))
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
