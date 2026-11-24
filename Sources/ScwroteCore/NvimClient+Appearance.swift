/// What the appearance setting needs from nvim.
extension NvimClient {
    /// Sets `background`, as `:set background=…` does: nvim reloads the
    /// colorscheme and fires `OptionSet`. Only for an nvim whose `background`
    /// scwrote owns (see `BackgroundOwnership`).
    public func setBackground(_ background: NvimBackground) throws {
        _ = try request("nvim_set_option_value", [.string("background"), .string(background.rawValue), .map([:])])
    }
}
