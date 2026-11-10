/// The Lua that makes nvim report to the preview. Run it with
/// `nvim_exec_lua(lua, arguments(channel:sendsText:))`, from any connection:
/// it sends `scwrote_preview` notifications (decoded by `PreviewEvent`) to
/// that channel, starting with the current buffer.
///
/// It only reads nvim's state. Only real files count: no help, terminal or
/// scratch buffers, and no floating windows. A buffer is sent when a change is
/// done (leaving insert mode, a normal-mode change, a write), never per
/// keystroke in insert mode; the modified flag and cursor are sent at once.
/// Every file with unsaved changes is reported on install, and a file
/// unloaded with its changes thrown away is reported as no longer modified,
/// so the file browser can mark unsaved files that aren't on screen.
/// The buffer's text comes along only while `sendsText` and when its kind is
/// drawn from text; otherwise building it would cost nvim time on every edit
/// of a big file for nothing. Reinstalling replaces the autocommands (that is
/// how `sendsText` changes), and they remove themselves once the channel is
/// gone.
public enum PreviewAutocommands {
    /// The arguments for `lua`: the channel to report to, whether to send
    /// text, and which files have text worth sending, by extension and by
    /// filetype, decided the way `PreviewKind` decides.
    public static func arguments(channel: Int64, sendsText: Bool) -> [MessagePackValue] {
        func needsText(_ kinds: [String: PreviewKind]) -> MessagePackValue {
            .map(Dictionary(uniqueKeysWithValues: kinds.map { (.string($0.key), .bool($0.value.needsText)) }))
        }
        return [
            .int(channel),
            .bool(sendsText),
            .map([
                .string("extensions"): needsText(PreviewKind.byExtension),
                .string("filetypes"): needsText(PreviewKind.byFiletype),
            ]),
        ]
    }

    public static let lua = """
        local chan, sends_text, previewable = ...
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

        -- Whether the preview draws this file from its text: the extension
        -- decides if PreviewKind knows it, otherwise the filetype.
        local function needs_text(buf, path)
          local ext = path:match("[^/]*$"):match("^.+%.([^.]*)$")
          local by_extension = ext and previewable.extensions[ext:lower()]
          if by_extension ~= nil then return by_extension end
          return previewable.filetypes[vim.bo[buf].filetype] == true
        end

        local function send_buffer()
          local buf = current_file()
          if not buf then return end
          local path = vim.api.nvim_buf_get_name(buf)
          local event = {
            type = "buffer",
            path = path,
            filetype = vim.bo[buf].filetype,
            modified = vim.bo[buf].modified,
            line = vim.fn.line("."),
            column = vim.fn.charcol(".") - 1,
          }
          if not (sends_text and needs_text(buf, path)) then
            event.omitted = "not_requested"
          elseif vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) > max_bytes then
            event.omitted = "too_large"
          else
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

        -- A file unloaded with its changes unwritten (`:bd!`) no longer has any.
        local function send_discarded(args)
          if not (is_file(args.buf) and vim.bo[args.buf].modified) then return end
          send({ type = "modified", path = vim.api.nvim_buf_get_name(args.buf), modified = false })
        end

        -- Every file with unsaved changes, current or not, for the file browser.
        local function send_unsaved()
          for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and is_file(buf) and vim.bo[buf].modified then
              send({ type = "modified", path = vim.api.nvim_buf_get_name(buf), modified = true })
            end
          end
        end

        -- No TextChangedI: text is sent on leaving insert mode, not per keystroke.
        vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged", "BufWritePost" },
          { group = group, callback = send_buffer })
        vim.api.nvim_create_autocmd("BufModifiedSet", { group = group, callback = send_modified })
        vim.api.nvim_create_autocmd("BufUnload", { group = group, callback = send_discarded })
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, callback = send_cursor })

        send_buffer()
        send_unsaved()
        """
}
