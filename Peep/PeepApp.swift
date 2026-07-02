import SwiftUI

extension Notification.Name {
    static let openArchive = Notification.Name("PeepOpenArchive")
}

struct ArchiveActions {
    var openPanel: () -> Void
    var extractSelection: () -> Void
    var extractAll: () -> Void
    var closeArchive: () -> Void
}

struct ArchiveWindowState {
    var hasArchive: Bool
    var selectionCount: Int
    var selectionIsDirectory: Bool?   // nil unless selectionCount == 1
}

private struct ArchiveActionsKey: FocusedValueKey {
    typealias Value = ArchiveActions
}

private struct ArchiveWindowStateKey: FocusedValueKey {
    typealias Value = ArchiveWindowState
}

extension FocusedValues {
    var archiveActions: ArchiveActions? {
        get { self[ArchiveActionsKey.self] }
        set { self[ArchiveActionsKey.self] = newValue }
    }
    var archiveWindowState: ArchiveWindowState? {
        get { self[ArchiveWindowStateKey.self] }
        set { self[ArchiveWindowStateKey.self] = newValue }
    }
}

private struct OpenArchiveCommand: View {
    @FocusedValue(\.archiveActions) private var actions

    var body: some View {
        Button("Open…") { actions?.openPanel() }
            .keyboardShortcut("o", modifiers: .command)
    }
}

private struct ExtractAndCloseCommands: View {
    @FocusedValue(\.archiveActions) private var actions
    @FocusedValue(\.archiveWindowState) private var state

    private var extractSelectionLabel: String {
        switch state?.selectionCount ?? 0 {
        case 0: return "Extract Selected"
        case 1: return (state?.selectionIsDirectory == true) ? "Extract Folder…" : "Extract File…"
        default: return "Extract \(state?.selectionCount ?? 0) Items…"
        }
    }

    var body: some View {
        Button(extractSelectionLabel) { actions?.extractSelection() }
            .keyboardShortcut("e", modifiers: .command)
            .disabled((state?.selectionCount ?? 0) == 0)
        Button("Extract All…") { actions?.extractAll() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!(state?.hasArchive ?? false))
        Divider()
        Button("Close Archive") { actions?.closeArchive() }
            .disabled(!(state?.hasArchive ?? false))
    }
}

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .openArchive, object: url)
    }
}

@main
struct PeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("appTheme") private var theme: AppTheme = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: theme, initial: true) { _, newTheme in
                    NSApp.appearance = newTheme.nsAppearance
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(after: .newItem) {
                OpenArchiveCommand()
            }
            CommandGroup(after: .saveItem) {
                ExtractAndCloseCommands()
            }
            // -[NSApplication terminate:] posts a notification whose handling calls
            // CFPasteboardResolveAllPromisedData, which hangs for tens of seconds after
            // any file has been dragged out via .onDrag, regardless of how the NSItemProvider
            // was built. exit(0) skips that path entirely; there's no unsaved state to protect.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Peep") { exit(0) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView()
                }
                Tab("Appearance", systemImage: "circle.lefthalf.filled") {
                    AppearanceSettingsView()
                }
                Tab("About", systemImage: "info.circle") {
                    AboutSettingsView()
                }
            }
            .frame(width: 460, height: 300)
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("openInFinderAfterExtract") private var openInFinderAfterExtract = false

    var body: some View {
        Form {
            Toggle("Open in Finder after extraction", isOn: $openInFinderAfterExtract)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var theme: AppTheme = .system

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(AppTheme.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}

struct AboutSettingsView: View {
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Peep")
                        .font(.title2).fontWeight(.semibold)
                    Text("Version \(appVersion)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Divider().padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 7) {
                Text("OPEN-SOURCE COMPONENTS")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                creditRow("ZIPFoundation", author: "Thomas Zoechling",
                          url: "https://github.com/weichsel/ZIPFoundation")
                creditRow("SWCompression", author: "Timofey Solomko",
                          url: "https://github.com/tsolomko/SWCompression")
                creditRow("MimeParser", author: "miximka",
                          url: "https://github.com/miximka/MimeParser")
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(width: 460, height: 300)
    }

    @ViewBuilder
    private func creditRow(_ name: String, author: String, url: String) -> some View {
        HStack(spacing: 4) {
            Link(name, destination: URL(string: url)!)
            Text("by \(author)")
                .foregroundStyle(.secondary)
            Spacer()
            Text("MIT")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.callout)
    }
}
