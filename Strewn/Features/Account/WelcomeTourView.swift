import SwiftUI

/// A short tour of what Batches is and how it works. New accounts see it once, after making a
/// profile and before the first batch; anyone can open it again from Account.
struct WelcomeTourView: View {
    /// The last page's button: "Start your first batch" during onboarding, "Done" from Account.
    var finishTitle = "Get started"
    let onFinish: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pages = TourPage.allCases

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(String(format: "%02d", page + 1)) / \(String(format: "%02d", Self.pages.count))")
                    .metaStyle(.caption)
                    .accessibilityLabel("Page \(page + 1) of \(Self.pages.count)")
                Spacer()
                if page < Self.pages.count - 1 {
                    Button("Skip", action: onFinish)
                        .font(.body)
                        .frame(minHeight: 44)
                        .accessibilityHint("Closes the tour")
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(Self.pages) { tourPage in
                    TourPageView(page: tourPage)
                        .tag(tourPage.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 18) {
                dots
                Button {
                    if page < Self.pages.count - 1 {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < Self.pages.count - 1 ? "Next" : finishTitle)
                }
                .buttonStyle(.paper(.primary))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(DeskMatBackground())
        .tint(.strewnAccent)
        .sensoryFeedback(.selection, trigger: page)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Self.pages) { tourPage in
                Capsule()
                    .fill(tourPage.rawValue == page ? Color.strewnAccent : Color.secondary.opacity(0.3))
                    .frame(width: tourPage.rawValue == page ? 20 : 7, height: 7)
            }
        }
        .animation(.snappy(duration: 0.25), value: page)
        .accessibilityHidden(true)
    }
}

// MARK: Pages

private enum TourPage: Int, CaseIterable, Identifiable {
    case welcome, desk, look, share, friends, yours
    var id: Int { rawValue }

    var kicker: String {
        switch self {
        case .welcome: "WELCOME TO BATCHES"
        case .desk: "YOUR DESK"
        case .look: "MAKE IT YOURS"
        case .share: "SHARING"
        case .friends: "FRIENDS"
        case .yours: "YOURS TO KEEP"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Photos, shared like a stack of prints"
        case .desk: "Every set is a batch"
        case .look: "Set the look"
        case .share: "Private until you share it"
        case .friends: "See what friends are sharing"
        case .yours: "Your photos stay yours"
        }
    }

    var body: String {
        switch self {
        case .welcome:
            "For the photos that belong together — a trip, an afternoon, a roll — shared with the people who were there."
        case .desk:
            "Batches sit on your desk as piles of prints. Tap one to spread it out. Press and hold to share, group or rename it."
        case .look:
            "Pick a frame, a font and a background, or arrange the prints by hand. Everyone who opens the batch sees it your way."
        case .share:
            "Share with a few people, your followers or anyone on Batches, and let friends add their own photos."
        case .friends:
            "Follow people to see their batches under Friends. Like and comment on a photo, @mention someone, or tag who's in it."
        case .yours:
            "Originals stay in your Photos library. Only screen-sized copies, without location, are uploaded."
        }
    }

    /// One or two short lines under the body, each with its own symbol.
    var points: [(symbol: String, text: String)] {
        switch self {
        case .welcome:
            [("rectangle.portrait.on.rectangle.portrait", "Every photo full frame. Nothing is cropped.")]
        case .desk:
            [("plus.circle.fill", "Make a batch with the + button.")]
        case .look:
            [("slider.horizontal.3", "Edit a photo here, or in the Photos app: Edit › ••• › Batches.")]
        case .share:
            [("link", "Send a batches.space link. It opens in the app or any browser.")]
        case .friends:
            [("bell", "Activity tells you when it's about you.")]
        case .yours:
            [("book.closed", "Lay batches out as a photobook at batches.space."),
             ("hand.raised", "Block or report anyone from their profile or a photo's menu.")]
        }
    }
}

private struct TourPageView: View {
    let page: TourPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    TourIllustration(page: page)
                        .frame(height: min(300, proxy.size.height * 0.48))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(page.kicker).metaStyle(.caption)
                        Text(page.title)
                            .titleStyle(.title, weight: .bold)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(page.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(page.points, id: \.text) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: point.symbol)
                                        .foregroundStyle(Color.strewnAccent)
                                        .frame(width: 22)
                                    Text(point.text)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Illustrations

/// Small drawings of each idea, made from the app's own pieces: framed prints on the linen,
/// stand-in photos as soft gradients, and the chips and pills the app uses.
private struct TourIllustration: View {
    let page: TourPage

    var body: some View {
        switch page {
        case .welcome: welcome
        case .desk: desk
        case .look: look
        case .share: share
        case .friends: friends
        case .yours: yours
        }
    }

    // A fan of prints, like a stack just dropped on the table.
    private var welcome: some View {
        ZStack {
            printCard(.dusk, width: 118, height: 150, kind: .polaroid, angle: -11).offset(x: -70, y: 10)
            printCard(.sea, width: 170, height: 114, kind: .whiteBorder, angle: 7).offset(x: 60, y: -26)
            printCard(.meadow, width: 150, height: 104, kind: .whiteBorder, angle: -3).offset(x: 4, y: 40)
        }
    }

    // Three piles on the desk, each with its caption.
    private var desk: some View {
        HStack(alignment: .bottom, spacing: 18) {
            pile([.sea, .dusk, .sand], caption: "Big Sur", angles: [-6, 5, -1])
            pile([.meadow, .sea], caption: "Saturday", angles: [7, -3])
                .offset(y: -24)
            pile([.dusk, .meadow, .sea], caption: "Roll 12", angles: [4, -7, 2])
        }
    }

    private func pile(_ tones: [Tone], caption: String, angles: [Double]) -> some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(tones.enumerated()), id: \.offset) { index, tone in
                    printCard(tone, width: 86, height: index.isMultiple(of: 2) ? 64 : 98, kind: .whiteBorder, border: 6,
                          angle: angles[index])
                }
            }
            .frame(height: 110)
            Text(caption).font(.system(.caption, design: .serif, weight: .semibold))
        }
    }

    // One photo in three frames, with the dock's controls under it.
    private var look: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                printCard(.sand, width: 62, height: 78, kind: .polaroid, border: 6, angle: -5)
                printCard(.sand, width: 78, height: 98, kind: .galleryMat, border: 7, angle: 0)
                printCard(.sand, width: 124, height: 82, kind: .filmStrip, border: 8, angle: 4)
            }
            HStack(spacing: 8) {
                chip("Frames", "square.inset.filled", on: true)
                chip("Font", "textformat")
                chip("Arrange", "hand.draw")
            }
        }
    }

    // A link card, as Messages shows it, with who it reaches.
    private var share: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Tone.sea.gradient
                    .frame(height: 112)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Big Sur, one afternoon").font(.subheadline.weight(.semibold)).foregroundStyle(Color.black)
                    Text("batches.space").font(.caption).foregroundStyle(Color.black.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.93))
            }
            .frame(width: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .rotationEffect(.degrees(-2))

            HStack(spacing: 8) {
                chip("Only me", "lock")
                chip("Followers", "person.3", on: true)
                chip("Anyone", "globe")
            }
        }
    }

    // A print with a like, a comment and a tag on it.
    private var friends: some View {
        ZStack {
            printCard(.meadow, width: 200, height: 140, kind: .whiteBorder, angle: -3)
            pill("@maya", symbol: "person.crop.circle")
                .offset(x: -18, y: -2)
            pill("12", symbol: "heart.fill", accent: true)
                .offset(x: 104, y: -86)
            bubble("Which beach was this?")
                .offset(x: -54, y: 100)
        }
    }

    // A small photobook, open, with the shield of the safety tools beside it.
    private var yours: some View {
        ZStack {
            HStack(spacing: 0) {
                bookPage(.sea, trailing: false)
                bookPage(.dusk, trailing: true)
            }
            .shadow(color: .black.opacity(0.2), radius: 14, y: 8)
            .rotationEffect(.degrees(-3))

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.onAccent)
                .frame(width: 56, height: 56)
                .background(Color.strewnAccent, in: Circle())
                .shadow(color: Color.strewnAccent.opacity(0.45), radius: 8, y: 4)
                .offset(x: 112, y: 70)
        }
    }

    private func bookPage(_ tone: Tone, trailing: Bool) -> some View {
        VStack(spacing: 8) {
            tone.gradient.frame(width: 96, height: 74)
            RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.12)).frame(width: 60, height: 3)
        }
        .padding(14)
        .frame(width: 126, height: 150)
        .background(Color.paper)
        .overlay(alignment: trailing ? .leading : .trailing) {
            LinearGradient(colors: [.black.opacity(0.12), .clear],
                           startPoint: trailing ? .leading : .trailing, endPoint: trailing ? .trailing : .leading)
                .frame(width: 14)
        }
    }

    // MARK: Pieces

    private func printCard(_ tone: Tone, width: CGFloat, height: CGFloat, kind: FrameStyle.Kind, border: CGFloat = 10,
                       angle: Double) -> some View {
        tone.gradient
            .frame(width: width, height: height)
            .photoFrame(FrameStyle(kind: kind, borderWidth: border))
            .rotationEffect(.degrees(angle))
    }

    private func chip(_ title: String, _ symbol: String, on: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .foregroundStyle(on ? Color.onAccent : Color.primary)
            .background(on ? Color.strewnAccent : Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(on ? 0 : 0.2), lineWidth: 1))
    }

    private func pill(_ text: String, symbol: String, accent: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(accent ? Color.onAccent : Color.white)
            .background(accent ? AnyShapeStyle(Color.strewnAccent) : AnyShapeStyle(.black.opacity(0.45)), in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func bubble(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.fill").foregroundStyle(Color.strewnAccent)
            Text(text).foregroundStyle(.primary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }

    /// Stand-in photos: soft two-colour gradients, like the samples on the first-batch screen.
    enum Tone {
        case sea, dusk, meadow, sand

        var gradient: LinearGradient {
            let colors: [Color] = switch self {
            case .sea: [Color(red: 0.42, green: 0.56, blue: 0.66), Color(red: 0.84, green: 0.68, blue: 0.50)]
            case .dusk: [Color(red: 0.34, green: 0.36, blue: 0.54), Color(red: 0.88, green: 0.58, blue: 0.34)]
            case .meadow: [Color(red: 0.28, green: 0.44, blue: 0.40), Color(red: 0.74, green: 0.78, blue: 0.72)]
            case .sand: [Color(red: 0.55, green: 0.66, blue: 0.72), Color(red: 0.86, green: 0.74, blue: 0.56)]
            }
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

#Preview {
    WelcomeTourView(finishTitle: "Start your first batch") {}
}
