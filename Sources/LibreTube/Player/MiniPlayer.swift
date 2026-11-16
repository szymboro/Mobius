import AVFoundation
import LibreTubeCore
import SwiftUI
import UIKit

// MARK: - Expanded player

/// Full-screen player above the TabView. Mounted while `NowPlaying` is expanded, and also kept
/// mounted (slid off screen) while Picture-in-Picture runs, so AVPlayerViewController and its PiP
/// session survive minimizing.
struct ExpandedPlayerHost: View {
    @ObservedObject private var nowPlaying = NowPlaying.shared

    var body: some View {
        ZStack {
            if let model = nowPlaying.model {
                ExpandedPlayerMount(model: model, isExpanded: nowPlaying.isExpanded)
                    .id(ObjectIdentifier(model))
                    // Child transitions don't run when their parent is inserted, so the mount
                    // carries the slide for a fresh open.
                    .transition(.slideOffScreen)
            }
        }
    }
}

private struct ExpandedPlayerMount: View {
    @ObservedObject var model: PlayerViewModel
    let isExpanded: Bool

    var body: some View {
        ZStack {
            if isExpanded || model.isPictureInPictureActive {
                ExpandedPlayer(model: model, isExpanded: isExpanded)
                    .transition(.slideOffScreen)
            }
        }
    }
}

/// Slides the player fully below the screen. `.move(edge: .bottom)` only moves a view by its own
/// (safe-area) height, but the player draws edge to edge, so its top ~90 pt stayed visible above
/// the tab bar until the animation settled.
private struct SlideOffScreen: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.visualEffect { effect, proxy in
            let insets = proxy.safeAreaInsets
            return effect.offset(y: isActive ? proxy.size.height + insets.top + insets.bottom : 0)
        }
    }
}

private extension AnyTransition {
    static var slideOffScreen: AnyTransition {
        .modifier(active: SlideOffScreen(isActive: true), identity: SlideOffScreen(isActive: false))
    }
}

private struct ExpandedPlayer: View {
    @ObservedObject var model: PlayerViewModel
    let isExpanded: Bool
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            VStack(spacing: 0) {
                header
                PlayerView(model: model, dragOffset: $dragOffset)
            }
            // Lay out inside the safe area, but let the background (and the clip) cover the whole
            // screen. Clipping the safe-area-sized frame left the home-indicator strip uncovered,
            // so the tab bar peeked through at the bottom.
            .padding(.top, insets.top)
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(width: proxy.size.width + insets.leading + insets.trailing,
                   height: proxy.size.height + insets.top + insets.bottom,
                   alignment: .top)
            .background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: dragOffset > 0 ? 24 : 0))
            .offset(y: isExpanded ? dragOffset : proxy.size.height + insets.bottom + insets.top)
            .ignoresSafeArea()
            .statusBarHidden(false)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
    }

    /// Just a grab handle: drag down here (or on the video) to minimize.
    private var header: some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(MinimizeDrag.gesture(offset: $dragOffset))
            .accessibilityElement()
            .accessibilityLabel("Minimize Player")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { NowPlaying.shared.minimize() }
    }
}

/// Drag down on the player (or its header) to minimize, with the view following the finger.
enum MinimizeDrag {
    @MainActor
    static func gesture(offset: Binding<CGFloat>) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { value in
                let dy = value.translation.height
                // Vertical drags only, so horizontal scrubbing in the player controls still works.
                guard dy > 0, offset.wrappedValue > 0 || dy > abs(value.translation.width) * 1.5 else { return }
                offset.wrappedValue = dy
            }
            .onEnded { value in
                let shouldMinimize = offset.wrappedValue > 0
                    && (value.translation.height > 140 || value.predictedEndTranslation.height > 360)
                if shouldMinimize {
                    NowPlaying.shared.minimize()
                }
                withAnimation(NowPlaying.spring) { offset.wrappedValue = 0 }
            }
    }
}

/// Auto plus the qualities this stream offers; a maximum for adaptive HLS.
struct QualityMenu: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        Menu {
            Picker(selection: selection) {
                Text(autoTitle).tag(0)
                ForEach(model.qualityOptions, id: \.self) { quality in
                    Text(title(for: quality)).tag(quality)
                }
            } label: {
                Text(model.qualityMode == .maximum ? "Maximum Quality" : "Quality")
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.isAudioOnly ? "Audio" : model.qualitySelection.map { "\($0)p" } ?? "Auto",
                  systemImage: "gearshape")
        }
        .menuStyle(.button)
        // No video is streamed in audio only (livestreams aside), so there is nothing to pick.
        .disabled(model.qualityMode == .unavailable || model.isAudioOnly)
        .accessibilityLabel("Quality")
        .accessibilityValue(model.qualitySelection.map { title(for: $0) } ?? autoTitle)
    }

    /// 0 stands for Auto.
    private var selection: Binding<Int> {
        Binding(
            get: { model.qualitySelection ?? 0 },
            set: { model.selectQuality($0 == 0 ? nil : $0) }
        )
    }

    private var autoTitle: String {
        guard model.qualitySelection == nil, let playing = model.playingQuality else { return "Auto" }
        return "Auto (\(playing)p)"
    }

    private func title(for quality: Int) -> String {
        var title = model.qualityMode == .maximum ? "Up to \(quality)p" : "\(quality)p"
        if model.qualitySelection == quality, model.qualityMode == .maximum,
           let playing = model.playingQuality, playing != quality {
            title += " (playing \(playing)p)"
        }
        return title
    }
}

// MARK: - Mini player bar

/// The bar above the tab bar while a video is minimized. `.accessory` is the iOS 26 tab view
/// bottom accessory, which draws its own glass; `.standalone` draws its own background.
struct MiniPlayerBar: View {
    enum Style {
        case standalone
        case accessory
    }

    var style: Style = .standalone
    @ObservedObject private var nowPlaying = NowPlaying.shared

    var body: some View {
        if let model = nowPlaying.model, !nowPlaying.isExpanded {
            switch style {
            case .standalone:
                MiniPlayerContent(model: model, clock: model.clock, style: .standalone, compact: false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .accessory:
                if #available(iOS 26, *) {
                    AccessoryMiniPlayer(model: model)
                } else {
                    MiniPlayerContent(model: model, clock: model.clock, style: .standalone, compact: false)
                }
            }
        }
    }
}

@available(iOS 26, *)
private struct AccessoryMiniPlayer: View {
    let model: PlayerViewModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayerContent(model: model, clock: model.clock, style: .accessory, compact: placement == .inline)
    }
}

private struct MiniPlayerContent: View {
    @ObservedObject var model: PlayerViewModel
    @ObservedObject var clock: PlaybackClock
    let style: MiniPlayerBar.Style
    /// The accessory is inline with a minimized tab bar: hide secondary details.
    let compact: Bool
    /// The live video joins only once the bar has settled. Created mid-animation, the player
    /// layer animated its video frame on its own and the picture flew across the screen.
    @State private var showsVideo = false

    private var barHeight: CGFloat {
        switch style {
        case .standalone: 64
        case .accessory: compact ? 36 : 48
        }
    }

    private var surfaceHeight: CGFloat {
        switch style {
        case .standalone: 48
        case .accessory: compact ? 24 : 34
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            surface
            VStack(alignment: .leading, spacing: 2) {
                Text(model.video?.title ?? "Loading…")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !compact, let uploader = model.video?.uploaderName, !uploader.isEmpty {
                    Text(uploader)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(model.player == nil)
            .accessibilityLabel(clock.isPlaying ? "Pause" : "Play")
            if !compact {
                Button {
                    NowPlaying.shared.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close Player")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, style == .standalone ? 8 : 6)
        .padding(.trailing, style == .standalone ? 8 : 12)
        .frame(height: barHeight)
        .overlay(alignment: .bottom) { progressLine }
        .background { standaloneBackground }
        .contentShape(Rectangle())
        .onTapGesture { NowPlaying.shared.expand() }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dy = value.translation.height
                    guard abs(dy) > abs(value.translation.width) else { return }
                    if dy < -24 || value.predictedEndTranslation.height < -80 {
                        NowPlaying.shared.expand()
                    } else if dy > 24 || value.predictedEndTranslation.height > 80 {
                        NowPlaying.shared.close()
                    }
                }
        )
        .padding(.horizontal, style == .standalone ? 8 : 0)
        .padding(.bottom, style == .standalone ? 6 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Expand Player") { NowPlaying.shared.expand() }
    }

    /// A live view of the same AVPlayer (AVPlayerViewController only exists when expanded),
    /// over the thumbnail, which shows while the bar animates in.
    private var surface: some View {
        ZStack {
            Color.black
            RemoteImage(url: model.video?.thumbnail)
            if showsVideo, let player = model.player, !model.isAudioOnly {
                PlayerLayerView(player: player)
                    .transition(.opacity)
            }
        }
        .frame(width: surfaceHeight * 16 / 9, height: surfaceHeight)
        .clipShape(.rect(cornerRadius: style == .standalone ? 8 : surfaceHeight / 4))
        .task(id: ObjectIdentifier(model)) {
            showsVideo = false
            try? await Task.sleep(for: .milliseconds(450)) // NowPlaying.spring settles by then
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { showsVideo = true }
        }
    }

    private var progressLine: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.tint)
                .frame(width: proxy.size.width * clock.progress, height: 2)
        }
        .frame(height: 2)
        .padding(.horizontal, style == .standalone ? 10 : 18)
        .padding(.bottom, style == .standalone ? 1 : 2)
        .opacity(clock.duration > 0 && !(model.streams?.isLive ?? false) ? 1 : 0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var standaloneBackground: some View {
        if style == .standalone {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
        }
    }
}

// MARK: - Video surface

/// Plain `AVPlayerLayer` on the shared AVPlayer (one player can drive several layers).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        view.player = player
    }

    static func dismantleUIView(_ view: PlayerLayerUIView, coordinator: ()) {
        view.player = nil
    }
}

final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        didSet {
            guard oldValue !== player else { return }
            attach()
        }
    }

    /// iOS pauses an AVPlayer that renders into a layer when the app goes to the background, so
    /// detach while backgrounded to keep audio playing (as Apple's background-playback guide says).
    private var isInBackground = UIApplication.shared.applicationState == .background

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// AVPlayerLayer positions its video in a sublayer, and sublayers animate implicitly: on a
    /// resize (e.g. the accessory turning compact) the picture slid into place from a corner.
    override func layoutSubviews() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        super.layoutSubviews()
        layer.layoutIfNeeded()
        CATransaction.commit()
    }

    private func attach() {
        let target = isInBackground ? nil : player
        if playerLayer.player !== target { playerLayer.player = target }
    }

    @objc private func didEnterBackground() {
        isInBackground = true
        attach()
    }

    @objc private func willEnterForeground() {
        isInBackground = false
        attach()
    }
}

// MARK: - Glass

extension View {
    /// A small circular control: interactive Liquid Glass on iOS 26, a material circle before.
    func glassCircle(size: CGFloat = 40) -> some View {
        modifier(GlassCircle(size: size))
    }
}

private struct GlassCircle: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        let sized = content
            .frame(width: size, height: size)
            .contentShape(Circle())
        if #available(iOS 26, *) {
            sized.glassEffect(.regular.interactive(), in: .circle)
        } else {
            sized.background(.regularMaterial, in: Circle())
        }
    }
}
