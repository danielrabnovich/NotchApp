import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var activity: ActivityCenter
    @EnvironmentObject private var tasks: TaskStore // collapsed width depends on the open count
    @EnvironmentObject private var timer: TimerStore // and on whether a timer is running
    @EnvironmentObject private var assistant: AssistantStore // …and on running searches
    @ObservedObject private var live = LiveActivities.shared // …and on the pinned live activities
    @ObservedObject private var speed = SpeedTest.shared // …and on a running speed test
    @ObservedObject private var videos = VideoDownloader.shared // …and on a video download
    @EnvironmentObject private var shelf: ShelfStore // collapsed height grows for the stack of quick drops

    var body: some View {
        let vm = viewModel
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        let body = vm.bodySize

        ZStack(alignment: .top) {
            // The shadow is only drawn once the shape has settled: re-rendering a large blurred
            // shadow on every frame of the spring is what made opening feel heavy.
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(vm.isSettled && settings.showShadow ? 0.6 : 0), radius: 14, y: 6)
                .animation(.easeOut(duration: 0.2), value: vm.isSettled)

            // Content is laid out once at its final size and revealed by the growing shape,
            // instead of being re-laid out on every animation frame.
            Group {
                if vm.isOpen {
                    OpenNotchView(viewModel: vm)
                        .frame(width: vm.openSize.width, height: vm.openSize.height, alignment: .top)
                        .transition(.asymmetric(
                            // A fade, not a scale: scaling would resize every AppKit-backed control
                            // inside on each frame of the opening animation.
                            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    CollapsedNotchView(viewModel: vm)
                        .frame(width: body.width, height: body.height, alignment: .top)
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }
            }
            .frame(width: vm.shapeSize.width, height: vm.shapeSize.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: vm.shapeSize.width, height: vm.shapeSize.height)
        .contentShape(shape)
        .onTapGesture {
            if !vm.isOpen { vm.open() }
        }
        .contextMenu {
            Button("Live Activities…") { SettingsWindowController.shared.show(pane: .live) }
            Button("Settings…") { SettingsWindowController.shared.show() }
            Divider()
            Button("Quit NotchApp") { NSApp.terminate(nil) }
        }
        .animation(vm.isOpen ? settings.openAnimation : settings.closeAnimation, value: vm.isOpen)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: vm.collapsedSize)
        .animation(.spring(response: 0.45, dampingFraction: 0.84), value: vm.openSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
