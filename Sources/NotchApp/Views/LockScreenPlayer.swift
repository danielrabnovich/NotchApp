import AppKit
import Combine
import SwiftUI

/// What's playing on the lock screen, under the clock: the artwork, the song, a scrub bar and the
/// controls, lit by the artwork's own colour. An ordinary window can't show there; this one is put
/// in a space of its own at the lock screen's level, through the window server's private
/// SkyLight calls (as the lock-screen widgets of other notch apps do). It's there only while the
/// Mac is locked and something is playing, and goes the moment it's unlocked.
@MainActor
final class LockScreenPlayer {
    static let shared = LockScreenPlayer()

    private var window: NSPanel?
    private var space: Int32 = 0
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let media = MediaController.shared
        Presence.shared.$locked
            .combineLatest(media.$title.map { !$0.isEmpty }, AppSettings.shared.$lockScreenMusic)
            .map { $0 && $1 && $2 }
            .removeDuplicates()
            .sink { [weak self] show in DispatchQueue.main.async { show ? self?.show() : self?.hide() } }
            .store(in: &cancellables)
    }

    private func show() {
        guard window == nil, let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? NSScreen.main,
              let sky = SkyLight.shared else { return }
        let size = CGSize(width: 380, height: 132)
        // Under the lock screen's clock, which takes the top quarter or so.
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - screen.frame.height * 0.36 - size.height)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = NSHostingView(rootView: LockPlayerView()
            .environmentObject(MediaController.shared)
            .environmentObject(AppSettings.shared))
        p.orderFrontRegardless()
        space = sky.lockScreenSpace()
        sky.move(windowNumber: p.windowNumber, to: space)
        window = p
    }

    func debugShow() { show() }
    func debugHide() { hide() }

    private func hide() {
        guard let p = window else { return }
        window = nil
        p.orderOut(nil)
        if space != 0 { SkyLight.shared?.destroy(space); space = 0 }
    }
}

/// The few SkyLight calls that make a space above the lock screen and move a window into it.
private final class SkyLight {
    static let shared = SkyLight()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias Destroy = @convention(c) (Int32, Int32) -> Int32

    private let connection: Int32
    private let create: SpaceCreate, setLevel: SetLevel, showSpaces: ShowSpaces, addWindows: AddWindows, destroySpace: Destroy

    /// The lock screen's level, which the notification banners shown over it use too.
    private static let lockLevel: Int32 = 400

    private init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let main = dlsym(h, "SLSMainConnectionID"), let c = dlsym(h, "SLSSpaceCreate"),
              let l = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let s = dlsym(h, "SLSShowSpaces"),
              let a = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces"), let d = dlsym(h, "SLSSpaceDestroy") else { return nil }
        connection = unsafeBitCast(main, to: MainConnection.self)()
        create = unsafeBitCast(c, to: SpaceCreate.self)
        setLevel = unsafeBitCast(l, to: SetLevel.self)
        showSpaces = unsafeBitCast(s, to: ShowSpaces.self)
        addWindows = unsafeBitCast(a, to: AddWindows.self)
        destroySpace = unsafeBitCast(d, to: Destroy.self)
    }

    func lockScreenSpace() -> Int32 {
        let space = create(connection, 1, nil)
        _ = setLevel(connection, space, Self.lockLevel)
        _ = showSpaces(connection, [space] as CFArray)
        return space
    }

    func move(windowNumber: Int, to space: Int32) {
        _ = addWindows(connection, space, [windowNumber] as CFArray, 7)
    }

    func destroy(_ space: Int32) { _ = destroySpace(connection, space) }
}

private struct LockPlayerView: View {
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let accent = settings.accent(for: media)
        HStack(spacing: 14) {
            AlbumArtView(image: media.artwork, size: 96, cornerRadius: 16)
                .shadow(color: accent.opacity(0.55), radius: 18, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(media.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                ScrubBar(accent: accent)
                HStack(spacing: 18) {
                    control("backward.fill", 15) { media.previousTrack() }
                    control(media.isPlaying ? "pause.fill" : "play.fill", 22) { media.togglePlayPause() }
                    control("forward.fill", 15) { media.nextTrack() }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 380, height: 132)
        .background {
            ZStack {
                VisualEffect(material: .hudWindow)
                LinearGradient(colors: [accent.opacity(0.28), .black.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
