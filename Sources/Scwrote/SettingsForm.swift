import ScwroteCore
import SwiftUI

/// The Settings window's one page. Each control applies and writes its setting
/// at once; while the file can't be read, a note says why and the controls are
/// off, so nothing is written over it.
struct SettingsForm: View {
    let store: SettingsStore

    var body: some View {
        Form {
            if let problem = store.problem {
                Text(Self.note(path: store.file.path, problem: problem)).foregroundStyle(.red)
            }
            Section("Appearance") {
                Picker(selection: modeBinding) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                } label: {
                    Text("Mode")
                    Text("System follows macOS.")
                }
                .pickerStyle(.segmented)
                .disabled(store.problem != nil)
            }
            Section("Quick open") {
                Toggle(isOn: binding(.showsHiddenFilesInQuickOpen)) {
                    Text("Show hidden files")
                    Text("Cmd+Shift+. in quick open changes this too.")
                }
                .disabled(store.problem != nil)
            }
            Section("Folders") {
                Toggle(isOn: binding(.reopensFolders)) {
                    Text("Reopen where I left off")
                    Text("Off: every launch starts fresh, as with --fresh.")
                }
                .disabled(store.problem != nil)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The parser's message usually ends in a period of its own.
    static func note(path: String, problem: String) -> String {
        let path = SettingsFile.displayPath(path, home: NSHomeDirectory())
        let message = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
        return "Couldn't read \(path): \(message). Fix the file to change settings here."
    }

    private func binding(_ key: SettingKey) -> Binding<Bool> {
        Binding(get: { key.value(in: store.settings) }, set: { _ = store.set(key, $0) })
    }

    private var modeBinding: Binding<AppearanceMode> {
        Binding(get: { store.settings.appearanceMode }, set: { _ = store.set($0) })
    }
}
