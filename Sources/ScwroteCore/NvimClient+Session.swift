import Foundation

/// How loading a folder's nvim session went.
public enum SessionRestore: Equatable, Sendable {
    /// The session loaded.
    case restored
    /// There was no session file.
    case missing
    /// A session was already loaded (the user's `-S`, or a session plugin),
    /// so scwrote left nvim alone.
    case skipped
    /// The session loaded with an error; whatever loaded stays.
    case failed(String)
}

/// What saving nvim's session did.
public enum SessionSave: Equatable, Sendable {
    /// The session was written.
    case saved
    /// No listed buffer had a file, so the session file was removed.
    case cleared
    /// Someone else's session is loaded (`v:this_session` is set: a session
    /// plugin that loaded after scwrote's restore), so the session file was
    /// left as it was.
    case skipped
}

/// nvim's side of reopening a folder where the user left off: a narrow
/// `:mksession` (files, splits, sizes, tabs, cursors, nothing of the user's
/// configuration), written when nvim exits or on request, and loaded back
/// after nvim starts without overriding the user's options. Paths travel as
/// Lua arguments, never spliced into a command.
extension NvimClient {
    /// Returns once nvim has finished starting (`v:vim_did_enter`): the user's
    /// config ran and the files on its command line are loaded. nvim can
    /// answer requests before that, whenever its startup lets events through
    /// (a config's `:sleep`, a plugin manager waiting), so an answer alone
    /// doesn't mean it's done. Asks every `interval`; a request that times out
    /// (nvim busy in a long config) is asked again. Throws when nvim can't be
    /// reached, e.g. because it exited.
    public func waitUntilStarted(interval: TimeInterval = 0.05) throws {
        while true {
            do {
                if case let .int(entered) = try request("nvim_get_vvar", [.string("vim_did_enter")]), entered != 0 {
                    return
                }
            } catch Failure.connectionLost {
                // Timed out (or the connection broke): try again, reconnecting.
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Whether a session is already loaded (`v:this_session` is set): the
    /// user's `-S`, or a session plugin's. scwrote doesn't save over it.
    public func isSessionLoaded() throws -> Bool {
        guard case let .string(session) = try request("nvim_get_vvar", [.string("this_session")]) else {
            return false
        }
        return !session.isEmpty
    }

    /// Installs a `ScwroteSession` augroup (replacing an earlier one) with a
    /// `VimLeavePre` autocommand that saves the session to `path`, as
    /// `saveSession(to:)` does. Errors then are dropped: a message at exit
    /// could hold nvim at a prompt. Waits as long as nvim takes to answer
    /// (it may still be busy with a slow restore queued ahead of it), so a
    /// slow nvim never ends up without the saver; a closed connection still
    /// ends the wait at once.
    public func installSessionSaver(path: String) throws {
        _ = try request("nvim_exec_lua", [
            .string(Self.saveFunctionLua + Self.installSaverLua),
            .array([.string(path)]),
        ], waitingOutTimeouts: true)
    }

    /// Saves the session to `path` now, for a window closing on a running
    /// nvim. `.skipped`, leaving `path` as it was, if `v:this_session` is set:
    /// someone else's session was loaded after scwrote's restore (which
    /// leaves it empty). `.cleared` if no listed buffer has a file name:
    /// `path` is deleted instead (no error if it's missing), so an empty
    /// session never replaces a real one. Otherwise `.saved`: `:mksession!`
    /// to `path` + `.tmp`, with `'sessionoptions'` set, for the write only,
    /// to `buffers,tabpages,winsize`, then renamed over `path`, so `path` is
    /// always a whole session. The user's `'sessionoptions'`, and the empty
    /// `v:this_session`, are put back even if the write fails, and a failed
    /// write leaves no `.tmp` behind and `path` as it was.
    @discardableResult
    public func saveSession(to path: String) throws -> SessionSave {
        let result = try request("nvim_exec_lua", [
            .string(Self.saveFunctionLua + "return save(...)"),
            .array([.string(path)]),
        ])
        switch result {
        case .string("cleared"): return .cleared
        case .string("skipped"): return .skipped
        default: return .saved
        }
    }

    /// Loads the session at `path` right after nvim starts. `.skipped` if
    /// `v:this_session` is already set (someone else's session is loaded:
    /// scwrote doesn't stack a second one on it); `.missing` if there's no
    /// file. Otherwise `:silent! source` it, so an error (the session's, or a
    /// plugin's autocommand as a file loads) doesn't stop the rest loading,
    /// with the global options a session file sets as they were at save time
    /// put back to the user's values after. Whatever loaded stays; an error
    /// makes the result `.failed` with nvim's (last) message, for logging.
    /// `v:this_session` is left empty either way, so nothing of the user's
    /// writes over scwrote's file. Waits as long as nvim takes to answer: a
    /// swap-file prompt for one of the session's files, or a heavy plugin,
    /// can hold the load up past the read timeout; a closed connection still
    /// ends the wait at once.
    ///
    /// After a load either way: unmodified listed buffers whose file no longer
    /// exists are wiped, unless named in `namedFiles` (the launch's named
    /// files, absolute; they may include values of nvim's flags). Then the
    /// first of `namedFiles` that nvim has as a buffer is shown in the current
    /// window, the others nvim has are kept listed, and the argument list is
    /// exactly the ones nvim has, in order; entries nvim doesn't have are
    /// ignored. If that first file is the one nvim's startup had in the
    /// current window and startup moved its cursor off the top (`+3`,
    /// `+/pattern`, `-c`, the user's last-position autocommand), that cursor
    /// and scroll win over the session's; otherwise the session's stay.
    public func restoreSession(from path: String, namedFiles: [String]) throws -> SessionRestore {
        let result = try request("nvim_exec_lua", [
            .string(Self.restoreLua),
            .array([.string(path), .array(namedFiles.map { .string($0) })]),
        ], waitingOutTimeouts: true)
        guard case let .array(parts) = result, case let .string(kind)? = parts.first else {
            return .failed("unexpected answer from nvim: \(result)")
        }
        switch kind {
        case "restored": return .restored
        case "missing": return .missing
        case "skipped": return .skipped
        default:
            if parts.count > 1, case let .string(message) = parts[1] { return .failed(message) }
            return .failed("unknown error")
        }
    }

    /// Defines a local `save(path)`, returning "saved", "cleared" or
    /// "skipped".
    private static let saveFunctionLua = """
        local function save(path)
          -- Set only by someone else's session (scwrote's restore leaves it
          -- empty): a plugin that loaded its own after scwrote's. Saving
          -- what that stacked up would replace the folder's session.
          if vim.v.this_session ~= "" then return "skipped" end
          local has_file = false
          for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
            if info.name ~= "" and vim.bo[info.bufnr].buftype == "" then
              has_file = true
              break
            end
          end
          if not has_file then
            os.remove(path)
            return "cleared"
          end
          -- :mksession! writes in place, and a kill or a full disk mid-write
          -- would leave a session that loads in part: write beside it, then
          -- rename over it. :mksession points v:this_session at the file it
          -- writes; it's put back to empty, or the user's own "save to
          -- v:this_session" code would write there with the user's full
          -- 'sessionoptions' (and scwrote would take it for someone else's).
          local tmp = path .. ".tmp"
          local users = vim.o.sessionoptions
          vim.o.sessionoptions = "buffers,tabpages,winsize"
          local ok, err = pcall(vim.cmd.mksession, { vim.fn.fnameescape(tmp), bang = true })
          vim.o.sessionoptions = users
          vim.v.this_session = ""
          if ok then
            local renamed, rename_err = os.rename(tmp, path)
            if not renamed then ok, err = false, rename_err end
          end
          if not ok then
            os.remove(tmp)
            error(err, 0)
          end
          return "saved"
        end

        """

    private static let installSaverLua = """
        local path = ...
        local group = vim.api.nvim_create_augroup("ScwroteSession", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", {
          group = group,
          callback = function() pcall(save, path) end,
        })
        """

    private static let restoreLua = """
        local path, named = ...
        if vim.v.this_session ~= "" then return { "skipped" } end
        if vim.fn.filereadable(path) == 0 then return { "missing" } end

        -- A session file sets these as they were at save time; the user's
        -- config wins. 'winminheight' and 'winminwidth' are 0 while the
        -- session loads and while the others are put back, so no
        -- 'winheight' or 'winwidth' can fail against them (a session sets
        -- the saved 'winheight', which errors below a larger 'winminheight'
        -- than the saving nvim had); then back to the user's values, which
        -- fit the user's 'winheight' and 'winwidth'.
        local names = { "winheight", "winwidth", "showtabline", "shortmess", "hlsearch",
          "splitbelow", "splitright", "scrolloff", "sidescrolloff" }
        local users = {}
        for _, name in ipairs(names) do users[name] = vim.go[name] end
        -- nvim's startup put the first named file in the current window. If
        -- it moved the cursor off the top (+3, +/pattern, -c, the user's
        -- last-position autocommand), that view wins over the one the
        -- session saved for the file, as `nvim <files>` has it; otherwise
        -- the session's stays.
        local startup_buf = vim.api.nvim_get_current_buf()
        local startup_view = vim.fn.winsaveview()
        local startup_moved = startup_view.lnum ~= 1 or startup_view.col ~= 0
        local users_wmh, users_wmw = vim.go.winminheight, vim.go.winminwidth
        vim.go.winminheight = 0
        vim.go.winminwidth = 0

        -- silent!: an error (the session's, or a plugin's autocommand while a
        -- file loads) doesn't stop the rest of the session loading. v:errmsg
        -- then holds the last one.
        local users_errmsg = vim.v.errmsg
        vim.v.errmsg = ""
        local ok, err = pcall(vim.cmd, { cmd = "source", args = { vim.fn.fnameescape(path) },
          mods = { emsg_silent = true } })
        if ok and vim.v.errmsg ~= "" then ok, err = false, vim.v.errmsg end
        if ok then vim.v.errmsg = users_errmsg end

        pcall(function() vim.go.winminheight = 0 end)
        pcall(function() vim.go.winminwidth = 0 end)
        for _, name in ipairs(names) do
          pcall(function() vim.go[name] = users[name] end)
        end
        pcall(function() vim.go.winminheight = users_wmh end)
        pcall(function() vim.go.winminwidth = users_wmw end)

        -- The session points v:this_session at scwrote's file; left so, the
        -- user's own "save to v:this_session" code would write over it.
        vim.v.this_session = ""
        -- Set while a session loads, for plugins; the session's last line
        -- clears it, unless it never got there.
        vim.g.SessionLoad = nil

        -- Named files: as given and in nvim's full form.
        local is_named = {}
        for _, name in ipairs(named) do
          is_named[name] = true
          is_named[vim.fn.fnamemodify(name, ":p")] = true
        end
        local by_name = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(buf)
          if name ~= "" then by_name[name] = buf end
        end

        -- Files deleted since the save don't come back as empty buffers.
        for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
          if info.name ~= "" and vim.bo[info.bufnr].buftype == "" and not vim.bo[info.bufnr].modified
              and not is_named[info.name] and vim.uv.fs_stat(info.name) == nil then
            pcall(vim.api.nvim_buf_delete, info.bufnr, {})
          end
        end

        local known = {}
        for _, name in ipairs(named) do
          local buf = by_name[name] or by_name[vim.fn.fnamemodify(name, ":p")]
          if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.bo[buf].buflisted = true
            table.insert(known, buf)
          end
        end
        if #known > 0 then
          vim.cmd.buffer(tostring(known[1]))
          if known[1] == startup_buf and startup_moved then pcall(vim.fn.winrestview, startup_view) end
          -- The session empties the argument list; a launch on files has
          -- them as its arguments.
          vim.cmd("silent! %argdelete")
          for _, buf in ipairs(known) do
            vim.cmd.argadd(vim.fn.fnameescape(vim.api.nvim_buf_get_name(buf)))
          end
        end

        if ok then return { "restored" } end
        return { "failed", tostring(err) }
        """
}
