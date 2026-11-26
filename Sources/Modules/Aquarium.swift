import SwiftUI

/// Круглый аквариум Pomodoro. Всё считается из времени и прогресса — без хранения состояния:
/// кран сверху, из него капают капли; капля падает с ускорением, сливается с водой —
/// ямка, отскок, брызги, кольцо волн (с отражением от стенок) и раскачивание всей воды.
/// Уровень воды растёт с прогрессом, рыбок становится больше. На дне — песок, камушки, ламинарии.
enum Aquarium {
    private static func rnd(_ n: Int) -> CGFloat { Liquid.rnd(n) }

    /// Во сколько раз колебания сильнее «настоящих» — для наглядности.
    static let waveBoost: CGFloat = 1.8
    static let dropPeriod = 1.15

    private struct Hit { let x: CGFloat; let tau: CGFloat }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, t: Double,
                     progress: Double, running: Bool, sinceToggle: Double,
                     palette: LiquidPalette, backdrop: Image?) {
        let s = min(size.width, size.height)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = s * 0.47
        let top = c.y - R, bottom = c.y + R
        let tf = CGFloat(t)
        let p = CGFloat(min(1, max(0, progress)))
        let circle = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        let rest = palette.top == LiquidPalette.rest.top

        // Уровень воды: при 0 — чуть выше песка, при 1 — почти до верха
        let sandTop = bottom - R * 0.30
        let base = bottom - R * (0.42 + 1.26 * p)
        let halfAt: (CGFloat) -> CGFloat = { y in sqrt(max(0, R * R - (y - c.y) * (y - c.y))) }
        let wallL = c.x - halfAt(base), wallR = c.x + halfAt(base)

        // MARK: Капли
        let tapX = c.x + R * 0.16
        let tapTip = top + R * 0.16
        let g = R * 3.4                              // «ускорение свободного падения» в масштабе аквариума
        let fallTime = sqrt(2 * max(R * 0.1, base - tapTip) / g)
        let toggleAt = t - sinceToggle
        var hits: [Hit] = []
        var falling: [(y: CGFloat, v: CGFloat)] = []
        var hanging: CGFloat = 0                     // 0…1 — капля набухает на кране

        let first = Int(floor((t - 4.5) / dropPeriod)), last = Int(floor((t + 0.7) / dropPeriod))
        for n in first...last {
            let tn = Double(n) * dropPeriod + Double(rnd(n)) * 0.3
            let allowed = running ? tn >= toggleAt : tn < toggleAt
            guard allowed else { continue }
            let tau = CGFloat(t - tn)
            if tau < 0 {
                if tau > -0.55 { hanging = max(hanging, 1 + tau / 0.55) }
            } else if tau < fallTime {
                falling.append((tapTip + 0.5 * g * tau * tau, g * tau))
            } else if tau - fallTime < 4.5 {
                hits.append(Hit(x: tapX, tau: tau - fallTime))
            }
        }

        // MARK: Поверхность воды
        let k = 2 * CGFloat.pi / (s * 0.20)          // длина волны
        let speed = s * 0.85                         // скорость бега волны
        func surface(_ x: CGFloat) -> CGFloat {
            var y = s * 0.005 * sin(x / s * 9 + tf * 1.6) + s * 0.003 * sin(x / s * 17 - tf * 2.3)
            for h in hits {
                let tau = h.tau
                let decay = exp(-tau * 1.05)
                // бегущее кольцо волн + отражения от стенок
                for (src, gain) in [(h.x, CGFloat(1)), (2 * wallL - h.x, 0.55), (2 * wallR - h.x, 0.55)] {
                    let r = abs(x - src), front = speed * tau
                    let env = exp(-pow((r - front) / (s * 0.14), 2))
                    y += s * 0.030 * waveBoost * decay * gain * env * sin(k * (r - front))
                }
                // капля сливается: ямка → отскок вверх → затухающие колебания в точке удара
                let r0 = (x - h.x) / (s * 0.08)
                y += s * 0.055 * waveBoost * exp(-tau * 3.2) * cos(tau * 15) * exp(-r0 * r0)
                // вся вода качается от удара
                y += s * 0.016 * waveBoost * exp(-tau * 0.8) * sin(tau * 5.2) * ((x - c.x) / R)
            }
            return base + y
        }

        // Преломление: всё, что под водой, слегка «плывёт»
        func wob(_ y: CGFloat) -> CGFloat {
            y > base ? s * 0.010 * sin(y / s * 22 + tf * 2.6) + s * 0.004 * sin(y / s * 41 - tf * 3.1) : 0
        }

        ctx.drawLayer { l in
            l.clip(to: circle)

            // MARK: Фон
            let box = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
            if let backdrop {
                l.draw(backdrop, in: box)
                l.fill(Path(box), with: .color(Color(red: 0.2, green: 0.55, blue: 0.9).opacity(0.18)))
            } else {
                l.fill(Path(box), with: .linearGradient(
                    Gradient(colors: rest
                        ? [Color(red: 0.70, green: 0.95, blue: 0.92), Color(red: 0.20, green: 0.62, blue: 0.68), Color(red: 0.05, green: 0.32, blue: 0.42)]
                        : [Color(red: 0.72, green: 0.90, blue: 1.00), Color(red: 0.25, green: 0.58, blue: 0.92), Color(red: 0.06, green: 0.24, blue: 0.58)]),
                    startPoint: CGPoint(x: c.x, y: top), endPoint: CGPoint(x: c.x, y: bottom)))
                // солнечные лучи сверху
                l.drawLayer { rays in
                    rays.blendMode = .plusLighter
                    for i in 0..<4 {
                        let x0 = c.x + R * (-0.6 + CGFloat(i) * 0.42) + R * 0.08 * sin(tf * 0.3 + CGFloat(i))
                        var ray = Path()
                        ray.move(to: CGPoint(x: x0 - R * 0.05, y: top))
                        ray.addLine(to: CGPoint(x: x0 + R * 0.06, y: top))
                        ray.addLine(to: CGPoint(x: x0 + R * 0.30, y: bottom))
                        ray.addLine(to: CGPoint(x: x0 + R * 0.05, y: bottom))
                        ray.closeSubpath()
                        rays.fill(ray, with: .color(.white.opacity(0.05 + 0.03 * Double(sin(tf * 0.7 + CGFloat(i) * 2)))))
                    }
                }
            }

            // MARK: Песок и камушки
            var sand = Path()
            sand.move(to: CGPoint(x: c.x - R, y: bottom))
            for i in 0...24 {
                let x = c.x - R + 2 * R * CGFloat(i) / 24
                sand.addLine(to: CGPoint(x: x, y: sandTop + R * 0.035 * sin(x / R * 3.1 + 1) + R * 0.02 * sin(x / R * 7.3)))
            }
            sand.addLine(to: CGPoint(x: c.x + R, y: bottom))
            sand.closeSubpath()
            l.fill(sand, with: .linearGradient(
                Gradient(colors: [Color(red: 0.93, green: 0.83, blue: 0.62), Color(red: 0.74, green: 0.60, blue: 0.40)]),
                startPoint: CGPoint(x: c.x, y: sandTop - R * 0.05), endPoint: CGPoint(x: c.x, y: bottom)))
            for i in 0..<26 {
                let x = c.x - R * 0.9 + rnd(i + 300) * R * 1.8
                let y = sandTop + R * 0.06 + rnd(i + 340) * R * 0.22
                let r = R * (0.008 + rnd(i + 380) * 0.012)
                l.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                       with: .color(Color(red: 0.55, green: 0.42, blue: 0.28).opacity(0.6)))
            }

            // MARK: Ламинарии (высокие широкие листья)
            let kelpX: [CGFloat] = [-0.66, -0.34, 0.30, 0.60]
            let kelpH: [CGFloat] = [1.05, 1.40, 1.25, 0.95]
            for i in 0..<kelpX.count {
                let bx = c.x + R * kelpX[i]
                let by = sandTop + R * 0.06
                let h = R * kelpH[i]
                var left: [CGPoint] = [], right: [CGPoint] = []
                for j in 0...22 {
                    let f = CGFloat(j) / 22
                    let y = by - h * f
                    let under: CGFloat = y > base ? 1 : 0.35
                    let sway = R * 0.13 * sin(tf * 0.85 + CGFloat(i) * 1.7 + f * 2.4) * pow(f, 1.25) * under
                    let cx = bx + sway + wob(y)
                    var w = R * (0.02 + 0.10 * sin(.pi * pow(f, 0.75)) * (1 - 0.35 * f))
                    w *= 1 + 0.18 * sin(f * 19 + tf * 2.2 + CGFloat(i))       // волнистый край листа
                    left.append(CGPoint(x: cx - w, y: y))
                    right.append(CGPoint(x: cx + w, y: y))
                }
                var leaf = Path()
                leaf.move(to: left[0])
                for pt in left.dropFirst() { leaf.addLine(to: pt) }
                for pt in right.reversed() { leaf.addLine(to: pt) }
                leaf.closeSubpath()
                let green = i % 2 == 0 ? Color(red: 0.30, green: 0.55, blue: 0.22) : Color(red: 0.45, green: 0.52, blue: 0.18)
                l.fill(leaf, with: .linearGradient(Gradient(colors: [green.opacity(0.95), green.opacity(0.75)]),
                                                   startPoint: CGPoint(x: bx, y: by), endPoint: CGPoint(x: bx, y: by - h)))
                var rib = Path()
                rib.move(to: CGPoint(x: (left[0].x + right[0].x) / 2, y: left[0].y))
                for j in 1..<left.count { rib.addLine(to: CGPoint(x: (left[j].x + right[j].x) / 2, y: left[j].y)) }
                l.stroke(rib, with: .color(Color(red: 0.18, green: 0.32, blue: 0.10).opacity(0.7)), lineWidth: max(0.5, R * 0.012))
            }

            // камушки поверх ламинарий
            let pebbleColors: [Color] = [Color(white: 0.55), Color(red: 0.50, green: 0.44, blue: 0.38),
                                         Color(white: 0.38), Color(red: 0.62, green: 0.55, blue: 0.46)]
            for i in 0..<8 {
                let w = R * (0.10 + rnd(i + 500) * 0.12), h = w * (0.55 + rnd(i + 520) * 0.2)
                let x = c.x - R * 0.78 + rnd(i + 540) * R * 1.56
                let y = sandTop + R * 0.04 + rnd(i + 560) * R * 0.14
                let rect = CGRect(x: x - w / 2 + wob(y), y: y - h / 2, width: w, height: h)
                l.fill(Path(ellipseIn: rect), with: .color(pebbleColors[i % pebbleColors.count]))
                l.fill(Path(ellipseIn: rect.insetBy(dx: w * 0.25, dy: h * 0.3).offsetBy(dx: -w * 0.1, dy: -h * 0.15)),
                       with: .color(.white.opacity(0.18)))
            }

            // MARK: Рыбки — чем больше воды, тем больше рыбок
            let fishColors: [(Color, Color)] = [
                (Color(red: 1.0, green: 0.55, blue: 0.15), .white),                         // клоун
                (Color(red: 1.0, green: 0.82, blue: 0.20), Color(red: 1.0, green: 0.6, blue: 0.1)),
                (Color(red: 0.30, green: 0.55, blue: 1.00), Color(red: 1.0, green: 0.85, blue: 0.2)),
                (Color(red: 0.95, green: 0.32, blue: 0.38), Color(red: 1.0, green: 0.7, blue: 0.7)),
                (Color(red: 0.62, green: 0.40, blue: 0.95), Color(red: 1.0, green: 0.8, blue: 0.3)),
                (Color(red: 0.25, green: 0.85, blue: 0.70), Color(red: 0.1, green: 0.4, blue: 0.5)),
                (Color(red: 1.0, green: 0.65, blue: 0.75), .white),
                (Color(red: 0.95, green: 0.95, blue: 0.95), Color(red: 1.0, green: 0.5, blue: 0.2)),
            ]
            let yMin = base + R * 0.12, yMax = sandTop - R * 0.06
            for i in 0..<8 {
                let appear: CGFloat = i == 0 ? 1 : min(1, max(0, (p - CGFloat(i) / 8.5) / 0.05))
                guard appear > 0 else { continue }
                let span = max(0, yMax - yMin)
                var fy = yMin + span * rnd(i * 13 + 7) + R * 0.03 * sin(tf * 1.3 + CGFloat(i))
                if span < R * 0.08 { fy = (yMin + yMax) / 2 }
                let hw = max(R * 0.1, halfAt(fy) - R * 0.22)
                let ph = tf * (0.22 + rnd(i * 31) * 0.28) + rnd(i * 47) * 6.28
                let fx = c.x + hw * sin(ph) + wob(fy)
                let dir: CGFloat = cos(ph) >= 0 ? 1 : -1
                let len = R * (0.17 + rnd(i * 59) * 0.08) * min(1, 0.6 + span / R)
                drawFish(&l, at: CGPoint(x: fx, y: fy), length: len, dir: dir,
                         wag: sin(tf * 9 + CGFloat(i) * 2), colors: fishColors[i], alpha: appear)
            }

            // MARK: Пузырьки
            for i in 0..<7 {
                let period = 2.6 + rnd(i + 700) * 2.2
                let ph = CGFloat((t / Double(period) + Double(rnd(i + 720))).truncatingRemainder(dividingBy: 1))
                let y = sandTop - (sandTop - base) * ph
                guard y > base + R * 0.03 else { continue }
                let x = c.x + R * (-0.6 + rnd(i + 740) * 1.2) + R * 0.03 * sin(tf * 3 + CGFloat(i)) + wob(y)
                let r = R * (0.022 + rnd(i + 760) * 0.022) * (0.7 + 0.5 * ph)
                let b = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                l.fill(b, with: .color(.white.opacity(0.15)))
                l.stroke(b, with: .color(.white.opacity(0.65)), lineWidth: max(0.4, R * 0.008))
            }

            // MARK: Вода
            var water = Path()
            let steps = 48
            water.move(to: CGPoint(x: c.x - R, y: surface(c.x - R)))
            for i in 1...steps {
                let x = c.x - R + 2 * R * CGFloat(i) / CGFloat(steps)
                water.addLine(to: CGPoint(x: x, y: surface(x)))
            }
            var surfaceLine = water
            water.addLine(to: CGPoint(x: c.x + R, y: bottom + 2))
            water.addLine(to: CGPoint(x: c.x - R, y: bottom + 2))
            water.closeSubpath()

            l.fill(water, with: .linearGradient(
                Gradient(colors: [palette.liquid.opacity(0.20), palette.bottom.opacity(0.24), palette.deep.opacity(0.30)]),
                startPoint: CGPoint(x: c.x, y: base - R * 0.05), endPoint: CGPoint(x: c.x, y: bottom)))

            // блики света на дне и в толще воды
            l.drawLayer { ca in
                ca.clip(to: water)
                ca.blendMode = .plusLighter
                for i in 0..<5 {
                    var line = Path()
                    let y0 = base + (bottom - base) * (0.2 + CGFloat(i) * 0.17)
                    line.move(to: CGPoint(x: c.x - R, y: y0))
                    for j in 1...16 {
                        let x = c.x - R + 2 * R * CGFloat(j) / 16
                        line.addLine(to: CGPoint(x: x, y: y0 + R * 0.05 * sin(x / R * 5 + tf * 1.4 + CGFloat(i) * 1.3)))
                    }
                    ca.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: max(0.6, R * 0.02))
                }
            }

            // светлая кромка под поверхностью
            l.drawLayer { m in
                m.clip(to: water)
                m.fill(Path(CGRect(x: c.x - R, y: base - R * 0.1, width: 2 * R, height: R * 0.18)),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.22), .white.opacity(0)]),
                                             startPoint: CGPoint(x: c.x, y: base - R * 0.05),
                                             endPoint: CGPoint(x: c.x, y: base + R * 0.12)))
            }
            surfaceLine = surfaceLine.strokedPath(StrokeStyle(lineWidth: max(0.7, R * 0.025), lineCap: .round))
            l.fill(surfaceLine, with: .color(.white.opacity(0.75)))

            // MARK: Брызги и кольца от удара
            for h in hits where h.tau < 0.6 {
                let a = Double(1 - h.tau / 0.6)
                let ringW = R * (0.08 + h.tau * 0.9)
                l.stroke(Path(ellipseIn: CGRect(x: h.x - ringW, y: base - ringW * 0.12, width: 2 * ringW, height: ringW * 0.24)),
                         with: .color(.white.opacity(0.55 * a)), lineWidth: max(0.5, R * 0.012))
                for j in 0..<4 {
                    let vx = R * (-0.55 + CGFloat(j) * 0.37) * (0.8 + rnd(j + 900) * 0.4)
                    let vy = R * (1.25 + rnd(j + 920) * 0.5)
                    let x = h.x + vx * h.tau
                    let y = base - (vy * h.tau - 0.5 * g * h.tau * h.tau)
                    guard y < base + R * 0.02 else { continue }
                    let r = R * 0.022
                    l.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Color(red: 0.85, green: 0.95, blue: 1).opacity(0.85 * a)))
                }
            }

            // MARK: Кран и капли
            let pipeW = R * 0.12
            let pipe = Path(roundedRect: CGRect(x: tapX - pipeW / 2, y: top - R * 0.1, width: pipeW, height: tapTip - top + R * 0.08),
                            cornerRadius: pipeW * 0.3)
            l.fill(pipe, with: .linearGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0.85), Color(white: 0.5)]),
                                               startPoint: CGPoint(x: tapX - pipeW / 2, y: 0), endPoint: CGPoint(x: tapX + pipeW / 2, y: 0)))
            if hanging > 0 {
                let r = R * 0.045 * hanging
                drawDrop(&l, x: tapX, y: tapTip - R * 0.02 + r, r: r, stretch: 1 + hanging * 0.3)
            }
            for d in falling {
                let r = R * 0.045
                drawDrop(&l, x: tapX, y: d.y, r: r, stretch: 1.3 + min(1.6, d.v / (R * 4)))
            }
        }

        // MARK: Стекло
        ctx.stroke(circle, with: .color(.white.opacity(0.35)), lineWidth: max(1, s * 0.025))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R * 0.97, y: c.y - R * 0.97, width: R * 1.94, height: R * 1.94)),
                   with: .color(.black.opacity(0.18)), lineWidth: max(0.5, s * 0.01))
        var gloss = Path()
        gloss.addArc(center: c, radius: R * 0.84, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
        ctx.stroke(gloss, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: max(1, s * 0.03), lineCap: .round))
    }

    /// Капля: круг снизу и острый «хвост» сверху; на лету вытягивается от скорости.
    private static func drawDrop(_ l: inout GraphicsContext, x: CGFloat, y: CGFloat, r: CGFloat, stretch: CGFloat) {
        var d = Path()
        d.move(to: CGPoint(x: x, y: y - r * 1.6 * stretch))
        d.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x + r * 0.9, y: y - r * 0.6 * stretch))
        d.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        d.addQuadCurve(to: CGPoint(x: x, y: y - r * 1.6 * stretch), control: CGPoint(x: x - r * 0.9, y: y - r * 0.6 * stretch))
        d.closeSubpath()
        l.fill(d, with: .color(Color(red: 0.80, green: 0.93, blue: 1).opacity(0.80)))
        l.stroke(d, with: .color(.white.opacity(0.9)), lineWidth: max(0.4, r * 0.18))
        l.fill(Path(ellipseIn: CGRect(x: x - r * 0.45, y: y - r * 0.35, width: r * 0.4, height: r * 0.45)),
               with: .color(.white.opacity(0.9)))
    }

    /// Рыбка: тело-эллипс, виляющий хвост, плавник, глаз; у некоторых — полоски.
    private static func drawFish(_ l: inout GraphicsContext, at p: CGPoint, length L: CGFloat, dir: CGFloat,
                                 wag: CGFloat, colors: (Color, Color), alpha: CGFloat) {
        var f = l
        f.opacity = Double(alpha)
        f.translateBy(x: p.x, y: p.y)
        f.scaleBy(x: dir, y: 1)
        let h = L * 0.5
        // хвост
        var tail = Path()
        tail.move(to: CGPoint(x: -L * 0.38, y: 0))
        tail.addLine(to: CGPoint(x: -L * 0.62, y: -h * 0.55 + wag * h * 0.25))
        tail.addLine(to: CGPoint(x: -L * 0.56, y: wag * h * 0.2))
        tail.addLine(to: CGPoint(x: -L * 0.62, y: h * 0.55 + wag * h * 0.25))
        tail.closeSubpath()
        f.fill(tail, with: .color(colors.1.opacity(0.95)))
        // тело
        let body = Path(ellipseIn: CGRect(x: -L * 0.45, y: -h / 2, width: L * 0.9, height: h))
        f.fill(body, with: .linearGradient(Gradient(colors: [colors.0, colors.0.opacity(0.75)]),
                                           startPoint: CGPoint(x: 0, y: -h / 2), endPoint: CGPoint(x: 0, y: h / 2)))
        // полоски
        if colors.1 == .white {
            f.drawLayer { st in
                st.clip(to: body)
                for x in [-0.05, 0.2] as [CGFloat] {
                    st.fill(Path(CGRect(x: L * x, y: -h, width: L * 0.08, height: 2 * h)), with: .color(.white.opacity(0.9)))
                }
            }
        }
        // спинной плавник
        var fin = Path()
        fin.move(to: CGPoint(x: -L * 0.12, y: -h * 0.42))
        fin.addQuadCurve(to: CGPoint(x: L * 0.12, y: -h * 0.45), control: CGPoint(x: -L * 0.05, y: -h * 0.85))
        fin.closeSubpath()
        f.fill(fin, with: .color(colors.1.opacity(0.85)))
        // глаз
        let e = L * 0.085
        f.fill(Path(ellipseIn: CGRect(x: L * 0.22, y: -h * 0.22, width: e, height: e)), with: .color(.white))
        f.fill(Path(ellipseIn: CGRect(x: L * 0.24, y: -h * 0.18, width: e * 0.55, height: e * 0.55)), with: .color(.black))
    }
}
