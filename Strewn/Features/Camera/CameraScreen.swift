import AVKit
import SwiftUI

/// The Shoot tab: viewfinder with the live look, RAW mode, manual dials and look picker.
/// Always dark, like a camera, regardless of the system theme.
///
/// On the viewfinder: tap to focus (and meter, in auto exposure) on a spot, press and hold to
/// lock focus and exposure there, and tap AUTO to go back to the default centre focus.
struct CameraScreen: View {
    @Environment(AppModel.self) private var app
    @Bindable var camera: CameraModel
    @State private var showsPipeline = true
    @State private var blink = false
    /// The dial whose slider is out. nil = all tucked away, more room for the viewfinder.
    @State private var openDial: CameraModel.Dial?

    private static let amber = Color.strewnAccent

    var body: some View {
        VStack(spacing: 8) {
            topBar
            viewfinder
            controlDeck
            lookPicker
            shootRow
        }
        .padding(.vertical, 6)
        .background(Color(white: 0.04).ignoresSafeArea())
        .foregroundStyle(Color(white: 0.94))
        // Dark only here. preferredColorScheme would switch the whole window, flipping the
        // other tabs to dark every time you opened Shoot.
        .environment(\.colorScheme, .dark)
        .toolbarBackground(Color(white: 0.04), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .task { await camera.start() }
        // Camera Control button and volume buttons fire the shutter, like the system camera.
        .modifier(HardwareShutter { shoot() })
        .sensoryFeedback(.impact(weight: .heavy), trigger: camera.shutterCount)
        .sensoryFeedback(.selection, trigger: camera.lens)
        .onChange(of: camera.shutterCount) {
            blink = true
            withAnimation(.easeOut(duration: 0.18)) { blink = false }
        }
        // The pipeline description shows for a moment when the format changes, then gets
        // out of the way of the picture.
        .task(id: camera.format) {
            withAnimation(.easeOut(duration: 0.2)) { showsPipeline = true }
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.6)) { showsPipeline = false }
        }
        .alert("Camera", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            if camera.needsCameraAccess, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                Button("Not now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(camera.errorMessage ?? "")
        }
        .onDisappear { camera.stop() }
    }

    private func shoot() {
        Task { await camera.shoot(into: app) }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { camera.flash.toggle() } label: {
                Image(systemName: camera.flash ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(camera.flash ? Self.amber : Color(white: 0.94))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(camera.flash ? "Flash on" : "Flash off")
            Spacer()
            Button(action: camera.cycleFormat) {
                Label(camera.format.label, systemImage: camera.format == .heif ? "circle" : "circle.fill")
                    .font(.caption.monospaced().weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(camera.format == .heif ? .secondary : Self.amber)
            Spacer()
            Button { camera.showGrid.toggle() } label: {
                Image(systemName: "squareshape.split.3x3")
                    .foregroundStyle(camera.showGrid ? Self.amber : Color(white: 0.94))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(camera.showGrid ? "Hide grid" : "Show grid")
        }
        .padding(.horizontal, 12)
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraPreview(renderer: camera.preview)
            .aspectRatio(3 / 4, contentMode: .fit)    // full sensor frame, never cropped to fill
            .overlay { if camera.showGrid { ThirdsGrid() } }
            .overlay {
                FocusSurface(focusPoint: camera.focusPoint, locked: camera.focusLocked) { point, lock in
                    camera.focus(at: point, lock: lock)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(camera.look.name.uppercased())
                    .font(.caption2.monospaced())
                    .chip()
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if camera.focusLocked {
                    Text(camera.isManualExposure ? "AF LOCK" : "AE/AF LOCK")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Self.amber, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if camera.focusPoint != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { camera.resetFocus() }
                    } label: {
                        Label("AUTO", systemImage: "arrow.counterclockwise")
                            .font(.caption2.monospaced().weight(.semibold))
                            .chip()
                    }
                    .padding(6)
                    .accessibilityLabel("Reset focus to auto")
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if showsPipeline {
                        Text(pipelineLine)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if camera.lenses.count > 1 { lensPicker }
                }
                .padding(10)
            }
            .overlay {
                Color.black.opacity(blink ? 0.85 : 0).allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 8)
            .animation(.easeOut(duration: 0.2), value: camera.focusPoint == nil)
            .animation(.easeOut(duration: 0.2), value: camera.focusLocked)
    }

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach(camera.lenses) { lens in
                let selected = lens == camera.lens
                Button { camera.select(lens: lens) } label: {
                    Text(lens.label)
                        .font(.system(size: selected ? 12 : 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Self.amber : .white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(selected ? 0.6 : 0.35)))
                }
                .accessibilityLabel("\(lens.label) camera")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.25)))
        .animation(.snappy(duration: 0.2), value: camera.lens)
    }

    private var pipelineLine: String {
        let source = switch camera.format {
        case .bayerRAW: "Bayer RAW · single frame · no Smart HDR or Deep Fusion"
        case .proRAW: "Apple ProRAW · merged frames · Apple tone map off"
        case .heif: "Processed HEIF · Apple pipeline on · color not consistent"
        }
        return "\(source)\n→ linear Rec.2020 → \(camera.look.name) → HEIF 10-bit P3 + DNG"
    }

    // MARK: Control deck

    /// Four dial windows, like the top plate of a camera: each shows its live value (dimmed,
    /// with an A, while the camera is choosing). Tap one to bring out its control.
    private var controlDeck: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                dialWindow(.iso, value: isoValue, auto: camera.isoIndex == nil)
                dialWindow(.shutter, value: shutterValue, auto: camera.shutterIndex == nil)
                dialWindow(.wb, value: camera.effectiveKelvin.map { "\(Int($0))K" } ?? "AWB",
                           auto: camera.whiteBalanceMode == .auto)
                dialWindow(.ev, value: String(format: "%+.1f", camera.exposureBias), auto: false)
            }
            if let openDial {
                dialControl(openDial)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .tint(Self.amber)
        .padding(.horizontal, 12)
        .animation(.snappy(duration: 0.25), value: openDial)
        .sensoryFeedback(.selection, trigger: openDial)
    }

    private func dialWindow(_ dial: CameraModel.Dial, value: String, auto: Bool) -> some View {
        let open = openDial == dial
        return Button {
            openDial = open ? nil : dial
            if !open { camera.dial = dial }
        } label: {
            VStack(spacing: 3) {
                Text(dial == .wb ? "WB" : dial.rawValue)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).kerning(0.8)
                    .foregroundStyle(open ? Self.amber : Color(white: 0.5))
                HStack(spacing: 3) {
                    Text(value)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(auto ? Color(white: 0.62) : Color(white: 0.96))
                        .contentTransition(.numericText())
                        .lineLimit(1).minimumScaleFactor(0.7)
                    if auto {
                        Text("A").font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 2)
                            .background(Color(white: 0.62), in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                .animation(.default, value: value)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: open ? 0.16 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(open ? Self.amber.opacity(0.7) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dial.rawValue), \(value)\(auto ? ", automatic" : "")")
        .accessibilityHint(open ? "Hides the control" : "Shows the control")
    }

    @ViewBuilder
    private func dialControl(_ dial: CameraModel.Dial) -> some View {
        HStack(spacing: 10) {
            switch dial {
            case .ev:
                Slider(value: $camera.exposureBias, in: -3...3, step: 1 / 3)
            case .iso:
                Slider(value: Binding(get: { Double(camera.isoIndex ?? 4) }, set: { camera.isoIndex = Int($0) }),
                       in: 0...Double(CameraModel.isoStops.count - 1), step: 1)
                    .opacity(camera.isoIndex == nil ? 0.5 : 1)
            case .shutter:
                Slider(value: Binding(get: { Double(camera.shutterIndex ?? 4) }, set: { camera.shutterIndex = Int($0) }),
                       in: 0...Double(CameraModel.shutterStops.count - 1), step: 1)
                    .opacity(camera.shutterIndex == nil ? 0.5 : 1)
            case .wb:
                Picker("White balance", selection: $camera.whiteBalanceMode) {
                    ForEach(CameraModel.WhiteBalanceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: camera.whiteBalanceMode == .kelvin ? 170 : .infinity)
                if camera.whiteBalanceMode == .kelvin {
                    Slider(value: $camera.kelvin, in: 2500...8000, step: 100)
                }
            }
            // Every dial can go back to its default: auto ISO and shutter, 0 EV.
            if dial != .wb {
                Button(dial == .ev ? "0" : "AUTO") {
                    withAnimation(.snappy) { camera.resetDial() }
                }
                .font(.caption2.monospaced().weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(camera.isDialAtDefault(dial))
                .accessibilityLabel(dial == .ev ? "Reset exposure compensation" : "Back to auto")
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 4)
    }

    private var isoValue: String {
        if let i = camera.isoIndex { return "\(Int(CameraModel.isoStops[i]))" }
        return camera.liveExposure.map { "\(Int($0.iso.rounded()))" } ?? "–"
    }

    private var shutterValue: String {
        if let i = camera.shutterIndex { return Self.shutterLabel(CameraModel.shutterStops[i]) }
        return camera.liveExposure.map { Self.shutterLabel($0.shutterSeconds) } ?? "1/–"
    }

    private static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "1/–" }
        return seconds >= 0.5 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }

    // MARK: Looks and shutter

    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(FilmLook.all) { look in
                            let selected = look.id == camera.look.id
                            Button { withAnimation(.snappy(duration: 0.2)) { camera.select(look) } } label: {
                                Text(look.name).font(.caption.weight(.semibold))
                                    .foregroundStyle(selected ? Self.amber : Color(white: 0.8))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
                            }
                            .id(look.id)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .scrollIndicators(.hidden)
                .onChange(of: camera.look.id) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            Text(camera.look.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 16)
        }
        .sensoryFeedback(.selection, trigger: camera.look.id)
    }

    private var shootRow: some View {
        HStack {
            ZStack {
                if let thumb = camera.lastShot {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(camera.rollCount)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12))
                }
                if camera.developing > 0 {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(width: 48, height: 48)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: camera.rollCount)
            .accessibilityLabel(camera.developing > 0 ? "Developing \(camera.developing) photos" : "Last photo")
            Spacer()
            Button(action: shoot) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4)
                    Circle().fill(.white).padding(camera.isCapturing ? 10 : 6)
                }
                .frame(width: 72, height: 72)
                .animation(.easeOut(duration: 0.12), value: camera.isCapturing)
            }
            .buttonStyle(.plain)
            .disabled(camera.isCapturing)
            .accessibilityLabel("Take photo")
            Spacer()
            VStack(spacing: 0) {
                Text("\(camera.rollCount)").font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: camera.rollCount)
                Text(camera.developing > 0 ? "DEV \(camera.developing)" : "SHOT").font(.system(size: 8.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 22)
    }
}

// MARK: - Focus

/// Catches taps and long presses on the viewfinder and draws the focus box where they landed.
private struct FocusSurface: View {
    let focusPoint: CGPoint?
    let locked: Bool
    var onFocus: (CGPoint, Bool) -> Void

    @State private var tapCount = 0
    @State private var pressHandled = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                guard case .second(true, let drag?) = value, !pressHandled else { return }
                                pressHandled = true
                                focus(drag.location, in: size, lock: true)
                            }
                            .onEnded { _ in pressHandled = false }
                            .exclusively(before: SpatialTapGesture().onEnded { focus($0.location, in: size, lock: false) })
                    )
                if let focusPoint {
                    FocusReticle(locked: locked)
                        .position(x: focusPoint.x * size.width, y: focusPoint.y * size.height)
                        .id(tapCount)
                        .allowsHitTesting(false)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
        .accessibilityHidden(true)
    }

    private func focus(_ location: CGPoint, in size: CGSize, lock: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let point = CGPoint(x: min(max(location.x / size.width, 0), 1), y: min(max(location.y / size.height, 0), 1))
        tapCount += 1
        onFocus(point, lock)
    }
}

/// The focus box: drops in from slightly larger, then dims unless focus is locked.
private struct FocusReticle: View {
    let locked: Bool
    @State private var settled = false
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(Color.strewnAccent, lineWidth: 1.5)
            .overlay {
                // Tick marks at the middle of each side, like a camera's AF point.
                GeometryReader { g in
                    Path { p in
                        let w = g.size.width, h = g.size.height, t: CGFloat = 6
                        p.move(to: .init(x: w / 2, y: 0)); p.addLine(to: .init(x: w / 2, y: t))
                        p.move(to: .init(x: w / 2, y: h)); p.addLine(to: .init(x: w / 2, y: h - t))
                        p.move(to: .init(x: 0, y: h / 2)); p.addLine(to: .init(x: t, y: h / 2))
                        p.move(to: .init(x: w, y: h / 2)); p.addLine(to: .init(x: w - t, y: h / 2))
                    }
                    .stroke(Color.strewnAccent, lineWidth: 1.5)
                }
            }
            .frame(width: 74, height: 74)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(dimmed && !locked ? 0.45 : 1)
            .task {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { settled = true }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.5)) { dimmed = true }
            }
    }
}

private struct ThirdsGrid: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3, y = g.size.height * CGFloat(i) / 3
                    p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: g.size.height))
                    p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: g.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Small dark label over the viewfinder.
    func chip() -> some View {
        padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Hooks the physical shutter inputs (Camera Control on iPhone 16, volume buttons) on iOS 18+.
private struct HardwareShutter: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent { event in
                if event.phase == .ended { action() }
            }
        } else {
            content
        }
    }
}
