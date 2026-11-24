/// What the light and dark colors settings need from nvim.
extension NvimClient {
    /// Sets the globals scwrote's colorscheme reads, then reloads it if it's
    /// the current one, so nvim recolors and reports its colors. Another
    /// colorscheme (one the config picked) is left alone.
    public func setColorChoices(light: LightColors, dark: DarkColors) throws {
        _ = try request("nvim_exec_lua", [
            .string("""
                local light, dark = ...
                vim.g.scwrote_light_colors = light
                vim.g.scwrote_dark_colors = dark
                if vim.g.colors_name == "scwrote" then vim.cmd.colorscheme("scwrote") end
                """),
            .array([.string(light.rawValue), .string(dark.rawValue)]),
        ])
    }
}
