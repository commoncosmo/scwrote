/// What the light and dark colors settings need from nvim.
extension NvimClient {
    /// Sets the globals scwrote's colorscheme reads, then reloads it if it's
    /// the current one and the palette for the current `background` changed,
    /// so nvim recolors and reports its colors. A choice for the mode that
    /// isn't showing waits for the switch, keeping a config's own highlight
    /// tweaks until then. Another colorscheme (one the config picked) is left
    /// alone.
    public func setColorChoices(light: LightColors, dark: DarkColors) throws {
        _ = try request("nvim_exec_lua", [
            .string("""
                local light, dark = ...
                local scwrote = vim.g.colors_name == "scwrote"
                local ok, colors = false, nil
                if scwrote then ok, colors = pcall(require, "scwrote.colors") end
                local before = ok and colors.current()
                vim.g.scwrote_light_colors = light
                vim.g.scwrote_dark_colors = dark
                if scwrote and (not ok or colors.current() ~= before) then vim.cmd.colorscheme("scwrote") end
                """),
            .array([.string(light.rawValue), .string(dark.rawValue)]),
        ])
    }
}
