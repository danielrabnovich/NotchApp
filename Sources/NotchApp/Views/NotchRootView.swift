import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var media: MediaController
    @EnvironmentObject private var activity: ActivityCenter
    @EnvironmentObject private var tasks: TaskStore // collapsed width depends on the open count
    @EnvironmentObject private var assistant: AssistantStore // …and on running searches

    var body: some View {
        let vm = viewModel
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        let body = vm.bodySize

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(vm.isOpen && settings.showShadow ? 0.6 : 0),
                        radius: vm.isOpen ? 14 : 0, y: 6)

            Group {
                if vm.isOpen {
                    OpenNotchView(viewModel: vm)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .top))
                                .animation(settings.openAnimation.delay(0.05)),
                            removal: .opacity.animation(.easeOut(duration: 0.12))))
                } else {
                    CollapsedNotchView(viewModel: vm)
                        .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }
            }
            .frame(width: body.width, height: body.height, alignment: .top)
            .clipped()

        }
        .frame(width: vm.shapeSize.width, height: vm.shapeSize.height)
        .contentShape(shape)
        .onTapGesture {
            if !vm.isOpen { vm.open() }
        }
        .contextMenu {
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
