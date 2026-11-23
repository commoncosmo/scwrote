/// The Lua that makes nvim report its colors. Run it with
/// `nvim_exec_lua(lua, arguments(channel:))`, from any connection: it sends
/// `scwrote_colors` notifications (decoded by `PreviewEvent`) to that channel.
///
/// A report goes out on install, on `ColorScheme`, on `OptionSet background`
/// and, when installed before startup finished, once on `VimEnter`, so a
/// colorscheme the config sets is reported; never per redraw or keystroke.
/// Like `PreviewAutocommands`, the autocommands remove themselves once the
/// channel is gone.
public enum ColorAutocommands {
    public static func arguments(channel: Int64) -> [MessagePackValue] {
        [.int(channel)]
    }

    public static let lua = """
        local chan = ...
        local names = {\(NvimColors.groupNames.map { "\"\($0)\"" }.joined(separator: ", "))}
        local group = vim.api.nvim_create_augroup("ScwroteColors", { clear = true })

        local function report()
          local groups = {}
          for _, name in ipairs(names) do
            local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
            groups[name] = { fg = hl.fg, bg = hl.bg }
          end
          local ok = pcall(vim.rpcnotify, chan, "\(NvimColors.method)", { background = vim.o.background, groups = groups })
          if not ok then
            -- scwrote went away: stop reporting to it.
            pcall(vim.api.nvim_del_augroup_by_id, group)
          end
        end

        report()
        vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = report })
        vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = report })
        if vim.v.vim_did_enter == 0 then
          vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = report })
        end
        """
}
