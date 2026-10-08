import AppKit
import Combine
import SwiftUI

/// Owns the notch panel for one screen and decides when it opens and closes.
@MainActor
final class NotchWindowController {
    let screen: NSScreen
    let viewModel: NotchViewModel
    private let panel: NotchPanel
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var swipe = SwipeState()
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    /// Extra transparent room around the open panel so its shadow isn't clipped.
    private static let shadowPadding: CGFloat = 40

    init(screen: NSScreen) {
        self.screen = screen
        let vm = NotchViewModel(notchSize: screen.notchSize, hasPhysicalNotch: screen.hasNotch)
        viewModel = vm

        let width = vm.maxOpenSize.width + 2 * 30 + 2 * Self.shadowPadding
        let height = vm.maxOpenSize.height + Self.shadowPadding
        let frame = NSRect(x: screen.notchCenterX - width / 2,
                           y: screen.frame.maxY - height,
                           width: width,
                           height: height)
        panel = NotchPanel(contentRect: frame)

        let root = NotchRootView(viewModel: vm)
            .environmentObject(AppSettings.shared)
            .environmentObject(MediaController.shared)
            .environmentObject(ActivityCenter.shared)
            .environmentObject(BatteryMonitor.shared)
            .environmentObject(CalendarManager.shared)
            .environmentObject(ShelfStore.shared)
            .environmentObject(TaskStore.shared)
            .environmentObject(AssistantStore.shared)
            .environmentObject(AudioOutputManager.shared)
            .environmentObject(SystemMonitor.shared)
            .environmentObject(TimerStore.shared)
            .environmentObject(ScratchpadStore.shared)
            .environmentObject(DownloadsStore.shared)
            .environmentObject(TaildropService.shared)
            .environmentObject(ControlsService.shared)
            .environmentObject(KeepAwake.shared)
            .environmentObject(UpdateChecker.shared)
            .environmentObject(AudioMixer.shared)
            .environmentObject(NetworkMonitor.shared)
            .environmentObject(SpeedTest.shared)
            .environmentObject(Cleaner.shared)
            .environmentObject(AppUninstaller.shared)
            .environmentObject(DeviceBatteries.shared)
            .environmentObject(PrivacyMonitor.shared)
            .environmentObject(ClipboardHistory.shared)
            .environmentObject(SystemTweaks.shared)
            .environmentObject(ControlTiles.shared)
            .environmentObject(PortScanner.shared)
            .environmentObject(AgentMonitor.shared)
            .environmentObject(VideoDownloader.shared)
            .environmentObject(VPNMonitor.shared)
            .environmentObject(MediaConverter.shared)
        let host = FirstMouseHostingView(rootView: AnyView(root))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) ?? event }
        }

        vm.takeKeyFocus = { [weak self] in
            guard let self, self.viewModel.isOpen else { return }
            self.panel.makeKey()
        }
        panel.onCancel = { [weak vm] in vm?.backOut() }

        // Hand keyboard focus back to the previous app once the notch closes.
        vm.$isOpen
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.relinquishKeyFocus() }
            .store(in: &cancellables)
    }

    var panelContentView: NSView? { panel.contentView }

    func close() {
        openWork?.cancel()
        closeWork?.cancel()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func relinquishKeyFocus() {
        guard panel.isKeyWindow else { return }
        // Stop being key right away (animating a key window is far costlier), but re-activate
        // the previous app only after the close animation, since that's a window-server round trip.
        panel.resignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, !self.viewModel.isOpen else { return }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                front.activate()
            }
        }
    }

    // MARK: - Hit testing

    /// A rect hanging from the top of the screen. It reaches a few points past the top edge:
    /// a pointer pushed against the top reports y == screen maxY, which `NSRect.contains`
    /// treats as outside, so the notch used to close (and clicks fell through to the menu bar).
    private func rect(width: CGFloat, height: CGFloat) -> NSRect {
        let overshoot: CGFloat = 4
        return NSRect(x: screen.notchCenterX - width / 2, y: screen.frame.maxY - height,
                      width: width, height: height + overshoot)
    }

    private var hotRect: NSRect {
        let size = viewModel.shapeSize
        // A small margin so brushing the open notch's edge doesn't snap it shut.
        if viewModel.isOpen { return rect(width: size.width + 12, height: size.height + 6) }
        // A little forgiveness around the collapsed notch.
        return rect(width: size.width + 16, height: size.height + 4)
    }

    /// The stack row hanging under the collapsed notch: hovering it fans the files out rather than
    /// opening the notch, so they can be dragged straight into another app.
    private var stackRect: NSRect? {
        guard !viewModel.isOpen, viewModel.showsStack else { return nil }
        let size = viewModel.shapeSize
        return NSRect(x: screen.notchCenterX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: NotchViewModel.stackHeight + 3)
    }

    private var dragHotRect: NSRect {
        let n = viewModel.notchSize
        return rect(width: n.width + 260, height: n.height + 90)
    }

    // MARK: - Mouse handling

    func handleMouse(_ kind: MouseEventKind) {
        if DebugHooks.pinned { return }
        let p = NSEvent.mouseLocation
        let dragging = MouseTracker.isExternalDrag && (settings.tasksEnabled || settings.shelfEnabled)
        let inside = hotRect.contains(p) || (dragging && dragHotRect.contains(p))
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        // Did the pointer itself move? When the notch shrinks under a still pointer (results
        // cleared, a tab with less content), that shouldn't count as leaving.
        let pointerMoved = p != lastPointer
        lastPointer = p

        // Each change is a window-server round trip, so only set it when it differs.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if kind == .up, viewModel.isDragActive {
            // Give the drop handler a moment to run, then return to normal.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !MouseTracker.isExternalDrag else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.viewModel.isDragActive = false }
            }
        }

        let onStack = !dragging && (stackRect?.contains(p) ?? false)
        if viewModel.stackHovered != onStack {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.stackHovered = onStack }
        }

        if inside {
            closeWork?.cancel()
            closeWork = nil
            if !viewModel.isHovering {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { viewModel.isHovering = true }
            }
            if dragging {
                openWork?.cancel()
                openWork = nil
                if !viewModel.isDragActive {
                    viewModel.dragPreview = TaskStore.preview(of: NSPasteboard(name: .drag))
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { viewModel.isDragActive = true }
                }
                viewModel.open(takeKeyboard: false) // a file drag: the drop bins, not typing
            } else if onStack {
                // Resting on the stack is for its files; a click opens the shelf.
                openWork?.cancel()
                openWork = nil
            } else if !viewModel.isOpen, settings.openMode == .hover, openWork == nil, !buttonDown {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.viewModel.isHovering { self.viewModel.open(takeKeyboard: AppSettings.shared.focusSearchOnHover) }
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + settings.hoverDelay, execute: work)
            }
        } else {
            if viewModel.isHovering {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.isHovering = false }
            }
            openWork?.cancel()
            openWork = nil

            guard viewModel.isOpen else { return }
            if kind == .down {
                viewModel.close()
            } else if viewModel.overlay != nil {
                // Briefs and nudges stay put until acted on or clicked away.
                return
            } else if dragging && viewModel.isDragActive {
                // Dragged past the notch without dropping: tuck it away again.
                scheduleClose(after: 0.3)
            } else if settings.openMode == .hover, !buttonDown, !viewModel.isEditing, pointerMoved {
                // Short grace period so brushing past the edge doesn't snap it shut.
                scheduleClose(after: 0.15)
            }
        }
    }

    private var lastPointer = NSPoint(x: -1, y: -1)

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if !self.hotRect.contains(NSEvent.mouseLocation) { self.viewModel.close() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Two-finger swipe between tabs

    private struct SwipeState {
        enum Axis { case undecided, horizontal, vertical }
        var axis: Axis = .undecided
        var accumulated = CGSize.zero
        var velocity: CGFloat = 0
        var lastTime: TimeInterval = 0
        var swallowMomentum = false
    }

    private func handleScroll(_ e: NSEvent) -> NSEvent? {
        guard e.window === panel, viewModel.isOpen, !viewModel.isDragActive, viewModel.overlay == nil else { return e }

        // Momentum after our own swipe would otherwise scroll lists underneath.
        if e.momentumPhase != [] {
            let swallow = swipe.swallowMomentum
            if e.momentumPhase.contains(.ended) { swipe.swallowMomentum = false }
            return swallow ? nil : e
        }
        // Mouse wheels have no phase: leave them to the views.
        guard e.phase != [] else { return e }

        let fingerDX = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX

        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            swipe = SwipeState()
            swipe.lastTime = e.timestamp
            rawOffset = 0
            return e
        }

        if e.phase.contains(.changed) {
            if swipe.axis == .undecided {
                swipe.accumulated.width += abs(e.scrollingDeltaX)
                swipe.accumulated.height += abs(e.scrollingDeltaY)
                guard swipe.accumulated.width + swipe.accumulated.height > 6 else { return e }
                let horizontal = swipe.accumulated.width > swipe.accumulated.height * 1.2
                if horizontal, !isInHorizontalScrollRegion(e) {
                    swipe.axis = .horizontal
                    viewModel.ensureNeighbors()
                    viewModel.isSwiping = true
                } else {
                    swipe.axis = .vertical
                }
            }
            guard swipe.axis == .horizontal else { return e }

            let dt = max(e.timestamp - swipe.lastTime, 1.0 / 240)
            swipe.velocity = swipe.velocity * 0.6 + (fingerDX / dt) * 0.4
            swipe.lastTime = e.timestamp
            rawOffset += fingerDX
            viewModel.pageOffset = rubberBanded(rawOffset)
            return nil
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            guard swipe.axis == .horizontal else { return e }
            finishSwipe()
            swipe.swallowMomentum = true
            return nil
        }
        return e
    }

    private var rawOffset: CGFloat = 0

    /// Debug: drives the same code path as a two-finger swipe (for profiling).
    func simulateSwipe(left: Bool) {
        guard viewModel.isOpen else { return }
        FrameProbe.mark("drag")
        swipe = SwipeState()
        swipe.axis = .horizontal
        viewModel.ensureNeighbors()
        viewModel.isSwiping = true
        rawOffset = 0
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                step += 1
                let dx: CGFloat = left ? -9 : 9
                self.swipe.velocity = dx * 120
                self.rawOffset += dx
                self.viewModel.pageOffset = self.rubberBanded(self.rawOffset)
                if step == 30 { t.invalidate(); self.finishSwipe() }
            }
        }
    }

    private func isInHorizontalScrollRegion(_ e: NSEvent) -> Bool {
        guard let host = panel.contentView else { return false }
        let p = CGPoint(x: e.locationInWindow.x, y: host.bounds.height - e.locationInWindow.y)
        return viewModel.horizontalScrollRegions.values.contains { $0.contains(p) }
    }

    /// Resists dragging past the first/last tab, like iOS scroll views.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        let tabs = viewModel.tabs
        let index = viewModel.tabIndex
        let w = viewModel.pageWidth
        let atStart = index == 0 && x > 0
        let atEnd = index == tabs.count - 1 && x < 0
        guard atStart || atEnd else { return max(-w, min(w, x)) }
        let c: CGFloat = 0.55
        let d = w * 0.5
        return (1 - 1 / (abs(x) * c / d + 1)) * d * (x < 0 ? -1 : 1)
    }

    private func finishSwipe() {
        FrameProbe.mark("settle")
        let tabs = viewModel.tabs
        var index = viewModel.tabIndex
        let w = viewModel.pageWidth
        let offset = viewModel.pageOffset
        let flick: CGFloat = 450

        if (offset < -w * 0.22 || swipe.velocity < -flick), index < tabs.count - 1 {
            index += 1
        } else if (offset > w * 0.22 || swipe.velocity > flick), index > 0 {
            index -= 1
        }
        let changed = tabs[index] != viewModel.tab
        rawOffset = 0

        // Carry the finger's speed into the snap so it feels continuous.
        let remaining = changed ? (w - abs(offset)) : abs(offset)
        let initialVelocity = remaining > 1 ? min(abs(swipe.velocity) / remaining, 12) : 0
        viewModel.slide(to: tabs[index],
                        animation: .interpolatingSpring(stiffness: 260, damping: 28, initialVelocity: initialVelocity))
        if changed {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
