import Foundation

/// macOS only lets a new app take focus while it still descends from the app
/// the user is typing in. The `scredit` launcher therefore stays alive until
/// the app is in front, and the app tells it so with SIGUSR1.
public enum LauncherHandoff {
    public static let environmentKey = "SCREDIT_NOTIFY_PID"

    /// The launcher to signal, or nil. Only a launcher that asked and is still
    /// this process's parent qualifies: SIGUSR1 kills a process that isn't
    /// listening for it.
    public static func pidToNotify(environmentValue: String?, parentPID: pid_t) -> pid_t? {
        guard let environmentValue, let pid = pid_t(environmentValue), pid > 1, pid == parentPID else {
            return nil
        }
        return pid
    }
}
