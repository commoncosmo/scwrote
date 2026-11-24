/// The Lua that makes nvim say, once, whether scwrote owns `background`. Run
/// it with `nvim_exec_lua(lua, arguments(channel:))`, from any connection: it
/// sends one `scwrote_background_owner` notification (decoded by
/// `PreviewEvent`) to that channel.
///
/// scwrote starts nvim with `--cmd "set background=…"`, which runs before the
/// user's config. A config (or a colorscheme it loads) that sets `background`
/// takes it over: then the option was last set by some other script. scwrote
/// owns it when it was never set, or last set by the `--cmd`. Like
/// `ColorAutocommands`, the answer waits for startup to finish: on install if
/// it has, else on `VimEnter`.
public enum BackgroundOwnership {
    public static let method = "scwrote_background_owner"

    /// The script ID nvim records for an option set by a `--cmd` argument
    /// (`SID_CMDARG`). Checked against nvim 0.12: `--cmd` gives -2, `-c` -3,
    /// Lua -8, and never set 0.
    static let commandArgumentScriptID = -2

    public static func arguments(channel: Int64) -> [MessagePackValue] {
        [.int(channel)]
    }

    public static let lua = """
        local chan = ...
        local group = vim.api.nvim_create_augroup("ScwroteBackground", { clear = true })

        local function report()
          local info = vim.api.nvim_get_option_info2("background", {})
          local owned = not info.was_set or info.last_set_sid == \(commandArgumentScriptID)
          pcall(vim.rpcnotify, chan, "\(method)", { owned = owned })
        end

        if vim.v.vim_did_enter == 1 then
          report()
        else
          vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = report })
        end
        """
}
