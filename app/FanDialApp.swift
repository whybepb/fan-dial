import SwiftUI

@main
struct FanDialApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = FanController()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: controller)
        } label: {
            Image(systemName: controller.snapshot.manual ? "fanblades.fill" : "fanblades")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FanController.restoreAutoOnQuit()
        return .terminateNow
    }
}

struct PopoverView: View {
    @ObservedObject var controller: FanController

    private let green = Color(red: 0.20, green: 0.84, blue: 0.42)

    var body: some View {
        VStack(spacing: 14) {
            DialView(controller: controller)
                .padding(.top, 6)

            fanReadout

            HStack(spacing: 8) {
                pill("Auto", active: !controller.snapshot.manual, tint: green) {
                    controller.setAuto()
                }
                pill("Max", active: false, tint: Color(red: 1.00, green: 0.33, blue: 0.30)) {
                    controller.setMax()
                }
                Spacer()
                if controller.applying {
                    ProgressView().controlSize(.small)
                }
                Button {
                    controller.toggleLaunchAtLogin()
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(controller.launchAtLogin ? green : Color(white: 0.3))
                            .frame(width: 5, height: 5)
                        Text("login")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color(white: 0.45))
                }
                .buttonStyle(.plain)
                .help("Start FanDial automatically at login")
                Button("quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.45))
            }

            if !controller.helperInstalled || controller.helperStale {
                Button {
                    controller.installHelper()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: controller.helperInstalled ? "arrow.triangle.2.circlepath" : "lock.open")
                            .font(.system(size: 9, weight: .semibold))
                        Text(controller.helperInstalled
                             ? "Update helper — newer build available (asks once)"
                             : "Stop asking for my password (installs helper, asks once)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(green.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if let err = controller.errorText {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.42))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 264)
        .background(Color(red: 0.055, green: 0.06, blue: 0.07))
        .preferredColorScheme(.dark)
    }

    private var fanReadout: some View {
        HStack(spacing: 10) {
            ForEach(controller.snapshot.fans, id: \.id) { fan in
                pair(label(for: fan), Text(verbatim: "\(Int(fan.actual.rounded()))"),
                     valueColor: Color(white: 0.75))
            }
            Spacer(minLength: 6)
            if let cpu = controller.snapshot.cpuTemp {
                pair("CPU", Text(verbatim: "\(Int(cpu.rounded()))°"), valueColor: tempColor(cpu))
            }
            if let gpu = controller.snapshot.gpuTemp {
                pair("GPU", Text(verbatim: "\(Int(gpu.rounded()))°"), valueColor: tempColor(gpu))
            }
        }
        .padding(.horizontal, 2)
    }

    private func pair(_ name: String, _ value: Text, valueColor: Color) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.42))
            value
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func tempColor(_ value: Double) -> Color {
        value >= 85 ? Color(red: 1.00, green: 0.45, blue: 0.42) : Color(white: 0.75)
    }

    private func label(for fan: FanInfo) -> String {
        if controller.snapshot.fans.count == 2 { return fan.id == 0 ? "L" : "R" }
        return "F\(fan.id)"
    }

    private func pill(_ title: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? tint : Color(white: 0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(active ? tint.opacity(0.18) : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
