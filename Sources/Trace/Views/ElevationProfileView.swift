import SwiftUI
import TraceCore

/// Profil altimétrique dessiné en Canvas (déterministe, survol synchronisé avec la carte).
struct ElevationProfileView: View {
    @ObservedObject var doc: TraceDocument
    @ObservedObject var controller: MapController
    @State private var hoverX: CGFloat?

    private let insets = EdgeInsets(top: 8, leading: 46, bottom: 22, trailing: 12)

    var body: some View {
        let samples = doc.profile
        VStack(alignment: .leading, spacing: 4) {
            header(samples)
            if samples.count >= 2 {
                GeometryReader { geo in
                    let plot = plotRect(geo.size)
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, size in draw(ctx: ctx, size: size, samples: samples) }
                        if let h = hovered(samples, plot: plot) {
                            let x = xFor(h.distance, samples: samples, plot: plot)
                            let y = yFor(h.elevation, samples: samples, plot: plot)
                            Path { p in p.move(to: CGPoint(x: x, y: plot.minY)); p.addLine(to: CGPoint(x: x, y: plot.maxY)) }
                                .stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            Circle().fill(.yellow).overlay(Circle().stroke(.black, lineWidth: 1.5))
                                .frame(width: 10, height: 10).position(x: x, y: y)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            hoverX = p.x
                            if let h = hovered(samples, plot: plot) { doc.hoverIndex = h.index }
                        case .ended:
                            hoverX = nil
                            doc.hoverIndex = nil
                        }
                    }
                    .onTapGesture { loc in
                        hoverX = loc.x
                        if let h = hovered(samples, plot: plot) {
                            let pts = doc.trackPoints
                            if pts.indices.contains(h.index) {
                                controller.center(on: .init(latitude: pts[h.index].lat, longitude: pts[h.index].lon))
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            } else {
                Text(doc.trackPoints.count >= 2 ? "Altitudes en cours de chargement…" : "Le profil altimétrique apparaît dès que le tracé a deux points.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    // MARK: - En-tête

    private func header(_ samples: [ProfileSample]) -> some View {
        HStack(spacing: 14) {
            let s = doc.stats
            Label(Stats.formatDistance(s.distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            if s.hasElevation {
                Label("+ " + Stats.formatElevation(s.ascent), systemImage: "arrow.up.right").foregroundStyle(.green)
                Label("- " + Stats.formatElevation(s.descent), systemImage: "arrow.down.right").foregroundStyle(.red)
                Label("\(Stats.formatElevation(s.minElevation ?? 0)) → \(Stats.formatElevation(s.maxElevation ?? 0))", systemImage: "mountain.2")
            }
            Spacer()
            if let i = doc.hoverIndex, let h = samples.min(by: { abs($0.index - i) < abs($1.index - i) }) {
                Text(String(format: "%@ · %.0f m · %+.1f %%", Stats.formatDistance(h.distance), h.elevation, h.grade))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.top, 8)
    }

    // MARK: - Géométrie

    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: insets.leading, y: insets.top, width: max(1, size.width - insets.leading - insets.trailing), height: max(1, size.height - insets.top - insets.bottom))
    }

    private func range(_ samples: [ProfileSample]) -> (minE: Double, maxE: Double, total: Double) {
        let minE = samples.map { $0.elevation }.min() ?? 0
        let maxE = samples.map { $0.elevation }.max() ?? 0
        let pad = max(10, (maxE - minE) * 0.12)
        return (minE - pad, maxE + pad, max(1, samples.last?.distance ?? 1))
    }

    private func xFor(_ d: Double, samples: [ProfileSample], plot: CGRect) -> CGFloat {
        plot.minX + plot.width * CGFloat(d / range(samples).total)
    }

    private func yFor(_ e: Double, samples: [ProfileSample], plot: CGRect) -> CGFloat {
        let r = range(samples)
        return plot.maxY - plot.height * CGFloat((e - r.minE) / (r.maxE - r.minE))
    }

    private func hovered(_ samples: [ProfileSample], plot: CGRect) -> ProfileSample? {
        guard let x = hoverX, plot.width > 0 else { return nil }
        let d = Double((min(max(x, plot.minX), plot.maxX) - plot.minX) / plot.width) * range(samples).total
        return samples.min { abs($0.distance - d) < abs($1.distance - d) }
    }

    // MARK: - Dessin

    private func draw(ctx: GraphicsContext, size: CGSize, samples: [ProfileSample]) {
        let plot = plotRect(size)
        let r = range(samples)
        let yTicks = niceTicks(min: r.minE, max: r.maxE, count: 4)
        for t in yTicks {
            let y = yFor(t, samples: samples, plot: plot)
            var p = Path(); p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(p, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            ctx.draw(Text(String(format: "%.0f m", t)).font(.system(size: 9)).foregroundColor(.secondary),
                     at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
        let km = r.total / 1000
        let xTicks = niceTicks(min: 0, max: km, count: 8)
        for t in xTicks where t <= km {
            let x = xFor(t * 1000, samples: samples, plot: plot)
            var p = Path(); p.move(to: CGPoint(x: x, y: plot.minY)); p.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(p, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            let label = km < 10 ? String(format: "%.1f km", t).replacingOccurrences(of: ".", with: ",") : String(format: "%.0f km", t)
            ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x, y: plot.maxY + 6), anchor: .top)
        }
        var line = Path()
        var area = Path()
        for (i, s) in samples.enumerated() {
            let pt = CGPoint(x: xFor(s.distance, samples: samples, plot: plot), y: yFor(s.elevation, samples: samples, plot: plot))
            if i == 0 {
                line.move(to: pt)
                area.move(to: CGPoint(x: pt.x, y: plot.maxY))
                area.addLine(to: pt)
            } else {
                line.addLine(to: pt)
                area.addLine(to: pt)
            }
        }
        if let last = samples.last {
            area.addLine(to: CGPoint(x: xFor(last.distance, samples: samples, plot: plot), y: plot.maxY))
            area.closeSubpath()
        }
        let accent = Color.accentColor
        ctx.fill(area, with: .linearGradient(Gradient(colors: [accent.opacity(0.35), accent.opacity(0.04)]), startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        ctx.stroke(line, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
    }

    private func niceTicks(min: Double, max: Double, count: Int) -> [Double] {
        guard max > min else { return [min] }
        let raw = (max - min) / Double(count)
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let step = (norm < 1.5 ? 1 : norm < 3 ? 2 : norm < 7 ? 5 : 10) * mag
        var out: [Double] = []
        var v = ceil(min / step) * step
        while v <= max { out.append(v); v += step }
        return out
    }
}
