/// The Lua that makes nvim report to the preview. Run it with
/// `nvim_exec_lua(lua, [channelID])`: it sends `scwrote_preview`
/// notifications (decoded by `PreviewEvent`) to that channel.
///
/// It only reads nvim's state. Only real files count: no help, terminal or
/// scratch buffers, and no floating windows. Text is sent when a change is
/// done (leaving insert mode, a normal-mode change, a write), never per
/// keystroke in insert mode; the modified flag and cursor are sent at once.
/// Reinstalling replaces the autocommands, and they remove themselves once
/// the channel is gone.
public enum PreviewAutocommands {
    public static let lua = """
        local chan = ...
        local max_bytes = \(PreviewLimits.maxBufferBytes)
        local group = vim.api.nvim_create_augroup("ScwrotePreview", { clear = true })

        local function is_file(buf)
          return vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
        end

        -- The current buffer, if it's a real file in a regular window.
        local function current_file()
          if vim.api.nvim_win_get_config(0).relative ~= "" then return nil end
          local buf = vim.api.nvim_get_current_buf()
          if not is_file(buf) then return nil end
          return buf
        end

        local function send(event)
          if not pcall(vim.rpcnotify, chan, "\(PreviewEvent.method)", event) then
            -- The preview went away: stop reporting to it.
            pcall(vim.api.nvim_del_augroup_by_id, group)
          end
        end

        local function send_buffer()
          local buf = current_file()
          if not buf then return end
          local event = {
            type = "buffer",
            path = vim.api.nvim_buf_get_name(buf),
            filetype = vim.bo[buf].filetype,
            modified = vim.bo[buf].modified,
            line = vim.fn.line("."),
            column = vim.fn.charcol(".") - 1,
          }
          if vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) <= max_bytes then
            event.text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\\n")
          end
          send(event)
        end

        local function send_cursor()
          local buf = current_file()
          if not buf then return end
          send({
            type = "cursor",
            path = vim.api.nvim_buf_get_name(buf),
            line = vim.fn.line("."),
            column = vim.fn.charcol(".") - 1,
          })
        end

        local function send_modified(args)
          if not is_file(args.buf) then return end
          send({
            type = "modified",
            path = vim.api.nvim_buf_get_name(args.buf),
            modified = vim.bo[args.buf].modified,
          })
        end

        -- No TextChangedI: text is sent on leaving insert mode, not per keystroke.
        vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged", "BufWritePost" },
          { group = group, callback = send_buffer })
        vim.api.nvim_create_autocmd("BufModifiedSet", { group = group, callback = send_modified })
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, callback = send_cursor })

        send_buffer()
        """
}
