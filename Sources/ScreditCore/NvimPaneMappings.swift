/// Ctrl-w mappings scredit adds to nvim for its session, so the file browser
/// works like a vim split left of nvim's windows: Ctrl-w h, w and W move
/// between nvim's windows as usual, and on to the browser where nvim has no
/// window that way. Nothing is written to the user's config, and a mapping
/// the user already has for one of these keys is left alone.
public enum NvimPaneMappings {
    /// What the mappings send scredit to ask for the browser.
    public static let browserRequest = NvimNotification(method: "scredit", params: [.string("browser")])

    /// Takes the channel to notify as its argument. Runs at VimEnter, after
    /// the user's config, so their mappings are there to be seen.
    static let lua = """
    local channel = ...

    -- True where nvim has no window that way: the browser is left of nvim's
    -- windows, and before the first and after the last in the Ctrl-w w cycle.
    local function past_edge(direction)
      local current = vim.fn.winnr()
      if direction == 'h' then return vim.fn.winnr('h') == current end
      if direction == 'w' then return current == vim.fn.winnr('$') end
      if direction == 'W' then return current == 1 end
      return false
    end

    local function setup()
      local keys = {
        ['<C-w>h'] = 'h', ['<C-w><C-h>'] = 'h',
        ['<C-w>w'] = 'w', ['<C-w><C-w>'] = 'w',
        ['<C-w>W'] = 'W',
      }
      for lhs, direction in pairs(keys) do
        if vim.fn.maparg(lhs, 'n') == '' then
          vim.keymap.set('n', lhs, function()
            -- With a count (2 Ctrl-w w: window 2) it's plain vim.
            local count = vim.v.count
            if count == 0 and past_edge(direction) then
              vim.rpcnotify(channel, 'scredit', 'browser')
            else
              vim.cmd((count > 0 and count or '') .. 'wincmd ' .. direction)
            end
          end, { desc = 'scredit: Ctrl-w ' .. direction .. ', on to the file browser past the edge' })
        end
      end
    end

    if vim.v.vim_did_enter == 1 then
      setup()
    else
      vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = setup })
    end
    """
}

public extension NvimClient {
    /// Adds the Ctrl-w mappings, reporting to this client's own channel: read
    /// `NvimPaneMappings.browserRequest` from `nextNotification()`.
    func installPaneMappings() throws {
        let channel = try channelID()
        _ = try request("nvim_exec_lua", [.string(NvimPaneMappings.lua), .array([.int(channel)])])
    }
}
