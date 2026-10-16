import AppKit
import SwiftUI

/// The card shown in its own window (AgentFileWindow) when the CLI agent changes a file (chat /agent!):
/// bordered, with the file name, the lines added or removed, one tab per file changed, and an undo button.
struct AgentFileView: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void
    /// Characters of added lines typed so far; the diff is replayed like live typing.
    @State private var typed = 0
    /// Mouse and window positions when the header drag began (screen coordinates).
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Changes whose typing has already played: showing them again is instant.
    @State private var played: Set<UUID> = []
    @State private var undoError: String?

    private var change: AgentChange? {
        state.agentChanges.first { $0.id == state.agentSelected } ?? state.agentChanges.last
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            if let change {
                let diff = change.diff
                HStack(alignment: .center, spacing: 0) {
                    BotCanvasView(state: state)
                        .frame(width: 64, height: 64)
                        .frame(width: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#9398A1"))
                            Text(diff.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(hex: "#F5F6F8"))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if diff.added > 0 {
                                Text("+\(diff.added)")
                                    .font(.system(size: 11, weight: .medium).monospaced())
                                    .foregroundColor(Color(hex: "#22C55E"))
                            }
                            if diff.removed > 0 {
                                Text("−\(diff.removed)")
                                    .font(.system(size: 11, weight: .medium).monospaced())
                                    .foregroundColor(Color(hex: "#F4505E"))
                            }
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(hex: "#9398A1"))
                            }
                            .buttonStyle(IconButtonStyle())
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in moveWindow() }.onEnded { _ in dragStart = nil })
                        if state.agentChanges.count > 1 { tabs }
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                let lines = visibleLines(of: diff)
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                        AgentDiffRow(line: line).id(index)
                                    }
                                }
                                .padding(8)
                                .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
                                .onChange(of: typed) { _, _ in proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        footer(change)
                    }
                    .padding(.trailing, 18)
                    .padding(.vertical, 16)
                }
                .task(id: change.id) {
                    if change.id == state.agentChanges.last?.id, !played.contains(change.id) {
                        await type(diff)
                    } else {
                        typed = addedCount(diff)
                    }
                    played.insert(change.id)
                }
                .onChange(of: state.agentSelected) { _, _ in undoError = nil }
            }
        }
    }

    /// One tab per file changed during the request.
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(state.agentChanges) { item in
                    let selected = item.id == change?.id
                    Button { state.agentSelected = item.id } label: {
                        Text(item.diff.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(selected ? Color(hex: "#F1F2F4") : Color(hex: "#9398A1"))
                            .strikethrough(item.undone)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(selected ? 0.12 : 0.06))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func footer(_ change: AgentChange) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: change.undone ? "Modification annulée." : (undoError ?? ""))
                .font(.system(size: 12))
                .foregroundColor(Color(hex: change.undone ? "#9398A1" : "#F4505E"))
                .lineLimit(1)
            Spacer(minLength: 2)
            if !change.undone {
                SecondaryButton(verbatim: "Annuler la modification") { undo(change) }
            }
        }
    }

    private func undo(_ change: AgentChange) {
        do {
            try change.undo()
            if let index = state.agentChanges.firstIndex(where: { $0.id == change.id }) {
                state.agentChanges[index].undone = true
            }
            undoError = nil
        } catch {
            undoError = error.localizedDescription
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

/// A diff line in the app's style: soft colours, rounded highlight, a bit more air than the hook diff card.
private struct AgentDiffRow: View {
    let line: DiffLine

    private var tint: Color? {
        switch line.kind {
        case .added: return Color(hex: "#22C55E")
        case .removed: return Color(hex: "#F4505E")
        case .context: return nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundColor(tint ?? Color(hex: "#454850"))
                .frame(width: 10, alignment: .leading)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundColor(tint == nil ? Color(hex: "#9398A1") : Color(hex: "#F1F2F4"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5).monospaced())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((tint ?? .clear).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
