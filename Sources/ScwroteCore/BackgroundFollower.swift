/// One window's choice of when to set nvim's `background` as the effective
/// appearance mode changes. nvim starts in the launch background; once
/// startup ends nvim says whether its config set `background` (and so owns
/// it). Only an nvim scwrote owns `background` in follows the mode, and a
/// change that arrives before that's known is held until it is.
///
/// It never reads nvim's state, so a manual `:set background` lasts until the
/// effective mode really changes.
public struct BackgroundFollower: Equatable, Sendable {
    /// The latest effective mode: what nvim was started with or last set to,
    /// or a change held while ownership is unknown.
    private var effective: NvimBackground
    private let launch: NvimBackground
    /// Nil until nvim reports, once, after its startup.
    private var owned: Bool?

    public init(launchedWith background: NvimBackground) {
        effective = background
        launch = background
    }

    /// nvim's word on who owns `background`. Returns the background to set
    /// now: a change held since launch, if scwrote owns it. Only the first
    /// call counts.
    public mutating func ownershipKnown(owned: Bool) -> NvimBackground? {
        guard self.owned == nil else { return nil }
        self.owned = owned
        return owned && effective != launch ? effective : nil
    }

    /// The effective mode is now `background`. Returns the background to set
    /// now, if it differs from the last one and scwrote owns `background`.
    public mutating func effectiveChanged(to background: NvimBackground) -> NvimBackground? {
        guard background != effective else { return nil }
        effective = background
        return owned == true ? background : nil
    }
}
