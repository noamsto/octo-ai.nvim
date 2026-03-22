local M = {}

--- Calculate float dimensions based on content and current editor size.
local function calc_dimensions(lines, opts)
  opts = opts or {}
  local max_width = math.floor(vim.o.columns * 0.85)
  local max_height = math.floor(vim.o.lines * 0.8)

  local width = opts.width or 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end
  width = math.min(math.max(width + 4, 60), max_width)

  local height = opts.height or math.min(#lines + 2, max_height)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  return { width = width, height = height, row = row, col = col }
end

--- Build a footer string from keybinding descriptions.
--- @param keys table<string, string> e.g. { q = "close", c = "comment", f = "followup" }
--- @return string
local function build_footer(keys)
  local parts = {}
  for key, desc in pairs(keys) do
    table.insert(parts, key .. " " .. desc)
  end
  table.sort(parts)
  return " " .. table.concat(parts, "  │  ") .. " "
end

--- Create a floating window with content, footer keybindings, and auto-resize.
--- @param title string Window title
--- @param lines string[] Content lines
--- @param opts? { ft?: string, width?: number, height?: number, keys?: table<string, {desc: string, fn: fun(bufnr: integer, winid: integer)}> }
--- @return integer bufnr
--- @return integer winid
function M.open_float(title, lines, opts)
  opts = opts or {}
  local key_defs = opts.keys or {}

  -- Build footer from key definitions
  local footer_keys = { q = "close" }
  for key, def in pairs(key_defs) do
    footer_keys[key] = def.desc
  end
  local footer = build_footer(footer_keys)

  local dim = calc_dimensions(lines, opts)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  if opts.ft then
    vim.bo[bufnr].filetype = opts.ft
  end

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = dim.row,
    col = dim.col,
    width = dim.width,
    height = dim.height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
  })

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true

  -- q / Esc close the float
  local function close_float()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end
  vim.keymap.set("n", "q", close_float, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close_float, { buffer = bufnr, silent = true })

  -- Register action keymaps
  for key, def in pairs(key_defs) do
    vim.keymap.set("n", key, function()
      def.fn(bufnr, winid)
    end, { buffer = bufnr, silent = true, desc = def.desc })
  end

  -- Auto-resize on VimResized (tmux pane zoom, terminal resize)
  local resize_group = vim.api.nvim_create_augroup("OctoAIFloat" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = resize_group,
    callback = function()
      if not vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_del_augroup_by_id, resize_group)
        return
      end
      local new_dim = calc_dimensions(lines, opts)
      vim.api.nvim_win_set_config(winid, {
        relative = "editor",
        row = new_dim.row,
        col = new_dim.col,
        width = new_dim.width,
        height = new_dim.height,
      })
    end,
  })

  -- Cleanup augroup when buffer is wiped
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = resize_group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, resize_group)
    end,
  })

  return bufnr, winid
end

--- Open a small input prompt. Calls callback with the input text.
--- @param title string
--- @param callback fun(input: string)
function M.input(title, callback)
  vim.ui.input({ prompt = title .. ": " }, function(input)
    if input and input ~= "" then
      callback(input)
    end
  end)
end

--- Show a persistent spinner notification while Claude is working.
--- @param msg string
--- @return fun()
function M.spinner(msg)
  local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local idx = 1
  local timer = vim.uv.new_timer()

  -- Use a fixed ID so replace always targets the same notification
  local id = "octo_ai_spinner"

  local function update()
    idx = (idx % #frames) + 1
    vim.notify(frames[idx] .. " " .. msg, vim.log.levels.INFO, {
      title = "octo-ai",
      id = id,
      timeout = false,
    })
  end

  update()
  timer:start(100, 100, vim.schedule_wrap(update))

  local dismissed = false
  return function()
    if dismissed then return end
    dismissed = true
    timer:stop()
    timer:close()
    vim.notify("Done", vim.log.levels.INFO, { title = "octo-ai", id = id, timeout = 2000 })
  end
end

--- Show the accept/reject/refine float for comment refinement.
--- @param original string
--- @param refined string
--- @param on_accept fun(text: string)
--- @param on_refine fun(feedback: string)
function M.refine_float(original, refined, on_accept, on_refine)
  local lines = {}
  table.insert(lines, "## Original")
  table.insert(lines, "")
  for _, l in ipairs(vim.split(original, "\n")) do
    table.insert(lines, "> " .. l)
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "## AI Refined")
  table.insert(lines, "")
  for _, l in ipairs(vim.split(refined, "\n")) do
    table.insert(lines, l)
  end

  M.open_float("Comment Refine", lines, {
    ft = "markdown",
    keys = {
      a = {
        desc = "accept",
        fn = function(_, winid)
          vim.api.nvim_win_close(winid, true)
          on_accept(refined)
        end,
      },
      x = {
        desc = "reject",
        fn = function(_, winid)
          vim.api.nvim_win_close(winid, true)
          vim.notify("AI refinement rejected", vim.log.levels.INFO)
        end,
      },
      r = {
        desc = "refine",
        fn = function(_, winid)
          vim.api.nvim_win_close(winid, true)
          M.input("Refinement feedback", on_refine)
        end,
      },
    },
  })
end

return M
