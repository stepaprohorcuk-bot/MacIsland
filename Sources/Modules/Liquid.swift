import AppKit
import SwiftUI

struct LiquidPalette {
    let top: Color            // цвет интерфейса (надписи, кнопка)
    let bottom: Color         // свечение
    let liquid: Color         // сама жидкость
    let deep: Color           // жидкость у дна

    // Вода: во время фокуса — голубая, в перерыве — бирюзовая
    static let focus = LiquidPalette(top: Color(red: 0.40, green: 0.78, blue: 1.00),
                                     bottom: Color(red: 0.10, green: 0.45, blue: 0.85),
                                     liquid: Color(red: 0.30, green: 0.70, blue: 1.00),
                                     deep: Color(red: 0.04, green: 0.25, blue: 0.62))
    static let rest = LiquidPalette(top: Color(red: 0.42, green: 0.93, blue: 0.80),
                                    bottom: Color(red: 0.10, green: 0.62, blue: 0.62),
                                    liquid: Color(red: 0.30, green: 0.88, blue: 0.80),
                                    deep: Color(red: 0.03, green: 0.38, blue: 0.45))

    static func `for`(_ phase: Phase) -> LiquidPalette { phase == .focus ? .focus : .rest }
}

/// Аквариум Pomodoro: вода капает из крана и наполняет его, рыбок становится больше.
struct LiquidOrb: View {
    @ObservedObject var model: PomodoroModel
    @ObservedObject var bg = BackgroundStore.shared
    var size: CGFloat
    var fps: Double = 60

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / fps)) { tl in
            let progress = model.progress(at: tl.date)
            let running = model.isRunning
            let since = tl.date.timeIntervalSince(model.runChangedAt)
            let palette = LiquidPalette.for(model.phase)
            let image = bg.hasCustom ? Image(nsImage: bg.image) : nil
            Canvas { ctx, sz in
                Aquarium.draw(in: &ctx, size: sz,
                              t: tl.date.timeIntervalSinceReferenceDate,
                              progress: progress, running: running, sinceToggle: since,
                              palette: palette, backdrop: image)
            }
        }
        .frame(width: size, height: size)
    }
}

enum Liquid {
    static func rnd(_ n: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return CGFloat(x % 100_000) / 100_000
    }
}

// MARK: - Картинка за аквариумом

@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()

    @Published private(set) var image: NSImage
    @Published private(set) var hasCustom: Bool

    private static var dir: URL { AppInfo.supportDir }
    private static var file: URL { dir.appendingPathComponent("background.png") }

    init() {
        if let img = NSImage(contentsOf: Self.file) {
            image = img; hasCustom = true
        } else {
            image = Self.makeDefault(); hasCustom = false
        }
    }

    func choose() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose a picture for the aquarium background")
        panel.prompt = L("Use")
        if panel.runModal() == .OK, let url = panel.url { set(url) }
    }

    @discardableResult
    func set(_ url: URL) -> Bool {
        guard let src = NSImage(contentsOf: url), let sq = Self.squareCrop(src, px: 512) else { return false }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        if let tiff = sq.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.file)
        }
        image = sq; hasCustom = true
        return true
    }

    func reset() {
        try? FileManager.default.removeItem(at: Self.file)
        image = Self.makeDefault(); hasCustom = false
    }

    /// Обрезка до квадрата и уменьшение — чтобы рисовать быстро.
    static func squareCrop(_ img: NSImage, px: Int) -> NSImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), side = min(w, h)
        guard let crop = cg.cropping(to: CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: px, height: px))
    }

    /// Картинка по умолчанию: закат с полосами и точками — на них хорошо видно преломление.
    static func makeDefault() -> NSImage {
        let px = 512
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let S = CGFloat(px)
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.98, green: 0.55, blue: 0.45, alpha: 1),
            CGColor(red: 0.55, green: 0.25, blue: 0.65, alpha: 1),
            CGColor(red: 0.10, green: 0.10, blue: 0.30, alpha: 1),
        ] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S), options: [])
        // солнце
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.45, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: S * 0.28, y: S * 0.42, width: S * 0.44, height: S * 0.44))
        // полосы через солнце
        ctx.setFillColor(CGColor(red: 0.55, green: 0.25, blue: 0.65, alpha: 1))
        for i in 0..<6 {
            let y = S * 0.44 + CGFloat(i) * S * 0.035
            ctx.fill(CGRect(x: S * 0.27, y: y, width: S * 0.46, height: S * (0.006 + 0.003 * CGFloat(i))))
        }
        // звёзды-точки
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
        for i in 0..<70 {
            let x = Liquid.rnd(i) * S, y = S * 0.5 + Liquid.rnd(i + 500) * S * 0.5
            let r = 1.5 + Liquid.rnd(i + 900) * 3
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        // сетка гор внизу
        ctx.setStrokeColor(CGColor(red: 1, green: 0.5, blue: 0.8, alpha: 0.55))
        ctx.setLineWidth(2)
        for i in 0..<9 {
            let y = S * 0.38 * pow(CGFloat(i) / 8, 1.6)
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: S, y: y))
        }
        for i in -8...8 {
            ctx.move(to: CGPoint(x: S / 2 + CGFloat(i) * S * 0.04, y: S * 0.38))
            ctx.addLine(to: CGPoint(x: S / 2 + CGFloat(i) * S * 0.2, y: 0))
        }
        ctx.strokePath()
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: px, height: px))
    }
}
