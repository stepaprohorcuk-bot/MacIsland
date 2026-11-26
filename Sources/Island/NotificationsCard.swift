import AppKit
import SwiftUI

/// Уведомления других программ стопкой, как на iPhone:
/// свёрнуто — видно самое свежее, под ним «слои» остальных; нажал — список раскрылся и листается.
/// Крестик в заголовке: первое нажатие — «Очистить всё», второе — удаляет.
struct NotificationsCard: View {
    @ObservedObject var watcher = NotificationWatcher.shared
    @State private var expanded = false
    @State private var confirmClear = false

    private var notes: [NotificationWatcher.Note] { watcher.recent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded && notes.count > 1 {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(notes) { n in
                            NoteRow(note: n, showsClose: true)
                                .onTapGesture { watcher.open(n) }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: notes.count <= 4)
            } else if let top = notes.first {
                stack(top)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: expanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: notes.count)
        .onChange(of: notes.count) { _, c in if c <= 1 { expanded = false } }
    }

    // MARK: Заголовок

    private var header: some View {
        HStack(spacing: 6) {
            Text("Notifications")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.secondary)
            if notes.count > 1 {
                Text("\(notes.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(Theme.secondary))
            }
            Spacer()
            if expanded && notes.count > 1 {
                headerButton(L("Collapse"), symbol: "chevron.up") { expanded = false }
            }
            if confirmClear {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { watcher.clearAll(); confirmClear = false }
                } label: {
                    Text("Clear all")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Capsule().fill(Color.red.opacity(0.75)))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { confirmClear = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { confirmClear = false } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(L("Clear all"))
            }
        }
        .frame(height: 22)
    }

    private func headerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Стопка

    private func stack(_ top: NotificationWatcher.Note) -> some View {
        let more = notes.count - 1
        return NoteRow(note: top, showsClose: more == 0)
            .background(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if more >= 2 {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .padding(.horizontal, 22)
                            .offset(y: 14)
                    }
                    if more >= 1 {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.13))
                            .padding(.horizontal, 11)
                            .offset(y: 7)
                    }
                }
            }
            .padding(.bottom, more >= 2 ? 14 : (more == 1 ? 7 : 0))
            .contentShape(Rectangle())
            .onTapGesture {
                if more > 0 { expanded = true } else { watcher.open(top) }
            }
            .help(more > 0 ? Lf("Show all %d notifications", notes.count) : (top.appName.map { Lf("Open %@", $0) } ?? ""))
    }
}

/// Одно уведомление: иконка программы, заголовок, время, текст.
struct NoteRow: View {
    let note: NotificationWatcher.Note
    var showsClose = true
    @State private var hover = false
    private let watcher = NotificationWatcher.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let i = note.icon { Image(nsImage: i).resizable() }
                else {
                    Image(systemName: "bell.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(note.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 4)
                    if hover && showsClose {
                        Button { withAnimation { watcher.dismiss(note) } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(L("Dismiss"))
                    } else {
                        Text(Self.relative(note.date))
                            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.tertiary)
                    }
                }
                if !note.body.isEmpty {
                    Text(note.body)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                if let app = note.appName {
                    Text(app).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: hover ? 0.2 : 0.17)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return L("now") }
        if s < 3600 { return Lf("%d min ago", Int(s / 60)) }
        return d.formatted(date: .omitted, time: .shortened)
    }
}
