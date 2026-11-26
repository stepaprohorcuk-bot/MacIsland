import AppKit
import SwiftUI

/// Smart Clipboard в острове: скриншоты миниатюрами (тащи в любое приложение), ниже — скопированный текст.
struct ClipboardCard: View {
    @ObservedObject var store = ClipboardStore.shared
    @ObservedObject var translator = Translator.shared
    var onCopied: (String) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Clipboard")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if !store.isEmpty {
                        Button(L("Clear")) { withAnimation { store.clear() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.tertiary)
                            .help(L("Remove everything except pinned items"))
                    }
                }
                if store.isEmpty {
                    Text("Copy some text or take a screenshot — it will appear here.")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !store.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.images) { ImageClip(item: $0, onCopied: onCopied) }
                        }
                    }
                    .frame(height: 50)
                }
                if !store.texts.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(store.texts) { TextClip(item: $0, onCopied: onCopied) }
                        }
                    }
                    .frame(maxHeight: 170)
                    .fixedSize(horizontal: false, vertical: store.texts.count <= 5)
                }
                if !store.isEmpty {
                    Text("Click to copy · drag into any app")
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.tertiary)
                }
                TranslationHost()
            }
        }
    }
}

struct ImageClip: View {
    let item: ClipboardStore.Item
    var onCopied: (String) -> Void
    @State private var hover = false
    private let store = ClipboardStore.shared

    var body: some View {
        let img = store.image(for: item)
        ZStack(alignment: .topTrailing) {
            Group {
                if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                else { Color.white.opacity(0.08) }
            }
            .frame(width: 72, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(hover ? Theme.accent : .white.opacity(0.1), lineWidth: hover ? 1.5 : 1))
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white).padding(3).background(Circle().fill(Theme.accent)).padding(3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.copy(item); onCopied(L("Image copied")) }
        .onDrag {
            if let u = store.url(for: item), let p = NSItemProvider(contentsOf: u) { return p }
            return NSItemProvider()
        }
        .contextMenu {
            Button(L("Copy")) { store.copy(item); onCopied(L("Image copied")) }
            Button(item.pinned ? L("Unpin") : L("Pin")) { store.togglePin(item) }
            if let u = store.url(for: item) { Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            Divider()
            Button(L("Delete"), role: .destructive) { withAnimation { store.delete(item) } }
        }
        .help(item.isScreenshot ? L("Screenshot") : L("Image"))
    }
}

struct TextClip: View {
    let item: ClipboardStore.Item
    var onCopied: (String) -> Void
    @ObservedObject var translator = Translator.shared
    @State private var hover = false
    private let store = ClipboardStore.shared

    var body: some View {
        let text = item.text ?? ""
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                }
                Text(text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hover || translator.busy.contains(item.id) || translator.results[item.id] != nil {
                    if translator.busy.contains(item.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        SmallIcon(symbol: "character.bubble", help: L("Translate"),
                                  tint: translator.results[item.id] != nil ? Theme.accent : Theme.secondary) {
                            translator.translate(id: item.id, text: text)
                        }
                    }
                }
                if hover {
                    SmallIcon(symbol: item.pinned ? "pin.slash" : "pin", help: item.pinned ? L("Unpin") : L("Pin")) {
                        store.togglePin(item)
                    }
                    SmallIcon(symbol: "xmark", help: L("Delete")) { withAnimation { store.delete(item) } }
                }
            }
            if let tr = translator.results[item.id] {
                HStack(alignment: .top, spacing: 6) {
                    Text(tr)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(Theme.accent.opacity(0.95))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    SmallIcon(symbol: "doc.on.doc", help: L("Copy translation")) {
                        store.copyText(tr); onCopied(L("Translation copied"))
                    }
                }
            } else if let err = translator.errors[item.id] {
                Text(err).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.white.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.copy(item); onCopied(L("Copied")) }
        .onDrag { NSItemProvider(object: text as NSString) }
        .help(String(text.prefix(400)))
    }
}
