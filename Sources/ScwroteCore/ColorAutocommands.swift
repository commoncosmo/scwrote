/// The Lua that makes nvim report its colors. Run it with
/// `nvim_exec_lua(lua, arguments(channel:))`, from any connection: it sends
/// `scwrote_colors` notifications (decoded by `PreviewEvent`) to that channel.
///
/// Nothing is reported before startup has finished: nvim answers RPC during
/// startup (a config's `vim.wait`, a plugin installer), when its colors may
/// still be the defaults the config's colorscheme replaces. So a report goes
/// out on install if startup is done, else once on `VimEnter`; then on
/// `ColorScheme` and `OptionSet background`, never per redraw or keystroke.
/// Those two schedule the report, so `ColorScheme` handlers registered after
/// these are included and `:set background`, which can fire both, sends one.
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
            groups[name] = { fg = hl.fg, bg = hl.bg, reverse = hl.reverse or nil }
          end
          local ok = pcall(vim.rpcnotify, chan, "\(NvimColors.method)", { background = vim.o.background, groups = groups })
          if not ok then
            -- scwrote went away: stop reporting to it.
            pcall(vim.api.nvim_del_augroup_by_id, group)
          end
        end

        local pending = false
        local function schedule_report()
          if vim.v.vim_did_enter ~= 1 or pending then return end
          pending = true
          vim.schedule(function()
            pending = false
            report()
          end)
        end

        vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = schedule_report })
        vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = schedule_report })
        if vim.v.vim_did_enter == 1 then
          report()
        else
          vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = report })
        end
        """
}
