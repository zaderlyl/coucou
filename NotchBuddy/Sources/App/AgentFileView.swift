import AppKit
import SwiftUI

/// The card shown in its own window (AgentFileWindow) when the CLI agent changes a file (chat /agent!):
/// bordered, with the file name and the lines added or removed.
struct AgentFileView: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void
    /// Characters of added lines typed so far; the diff is replayed like live typing.
    @State private var typed = 0
    /// Mouse and window positions when the header drag began (screen coordinates).
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    var body: some View {
        ZStack(alignment: .leading) {
            if let diff = state.agentFile {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(hex: "#9398A1"))
                        Text(diff.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if diff.added > 0 {
                            Text("+\(diff.added)")
                                .font(.system(size: 10, weight: .medium).monospaced())
                                .foregroundColor(Color(hex: "#22C55E"))
                        }
                        if diff.removed > 0 {
                            Text("−\(diff.removed)")
                                .font(.system(size: 10, weight: .medium).monospaced())
                                .foregroundColor(Color(hex: "#F4505E"))
                        }
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color(hex: "#5F646D"))
                                .frame(width: 14, height: 14)
                                .background(Color.white.opacity(0.07))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in moveWindow() }.onEnded { _ in dragStart = nil })
                    Divider().overlay(Color.white.opacity(0.08))
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            let lines = visibleLines(of: diff)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    DiffLineRowView(line: line).id(index)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
                            .onChange(of: typed) { _, _ in proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: "#141518"))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1))
                .task(id: diff) { await type(diff) }
            }
        }
    }

    /// Moves the window with the mouse by hand: a borderless panel does not drag itself under SwiftUI.
    private func moveWindow() {
        guard let panel = AgentFileWindow.shared.window else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func addedCount(_ diff: FileDiff) -> Int {
        diff.hunks.flatMap { $0.lines }.filter { $0.kind == .added }.reduce(0) { $0 + $1.text.count + 1 }
    }

    /// Removed and unchanged lines show at once; added lines appear character by character.
    private func visibleLines(of diff: FileDiff) -> [DiffLine] {
        var budget = typed
        var result: [DiffLine] = []
        for var line in diff.hunks.flatMap({ $0.lines }) {
            if line.kind == .added {
                if budget <= 0 { break }
                if budget < line.text.count + 1 {
                    line.text = String(line.text.prefix(budget))
                    result.append(line)
                    break
                }
                budget -= line.text.count + 1
            }
            result.append(line)
        }
        return result
    }

    /// About 2 seconds for a whole file, whatever its size, 60 steps a second at most.
    private func type(_ diff: FileDiff) async {
        typed = 0
        let total = addedCount(diff)
        let step = max(1, total / 120)
        while typed < total {
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            typed = min(total, typed + step)
        }
    }
}
