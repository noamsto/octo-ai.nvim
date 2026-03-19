local M = {}

--- Create a floating window with the given content.
--- @param title string Window title
--- @param lines string[] Content lines
--- @param opts? { ft?: string, width?: number, height?: number, on_key?: table<string, fun(bufnr: integer, winid: integer)> }
--- @return integer bufnr
--- @return integer winid
function M.open_float(title, lines, opts)
  opts = opts or {}

  local max_width = math.floor(vim.o.columns * 0.8)
  local max_height = math.floor(vim.o.lines * 0.7)

  local width = opts.width or 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end
  width = math.min(width + 2, max_width)

  local height = opts.height or math.min(#lines, max_height)

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"
  if opts.ft then
    vim.bo[bufnr].filetype = opts.ft
  end

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  -- q always closes
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
  end, { buffer = bufnr, silent = true })

  -- Register custom keymaps
  if opts.on_key then
    for key, fn in pairs(opts.on_key) do
      vim.keymap.set("n", key, function()
        fn(bufnr, winid)
      end, { buffer = bufnr, silent = true })
    end
  end

  return bufnr, winid
end

--- Open a small input prompt float. Calls callback with the input text.
--- @param title string
--- @param callback fun(input: string)
function M.input(title, callback)
  vim.ui.input({ prompt = title .. ": " }, function(input)
    if input and input ~= "" then
      callback(input)
    end
  end)
end

--- Show a spinner notification while waiting for Claude.
--- Returns a function to dismiss it.
--- @param msg string
--- @return fun()
function M.spinner(msg)
  local id = vim.notify(msg .. " ...", vim.log.levels.INFO, { title = "octo-ai" })
  return function()
    -- Dismiss by replacing with empty (works with nvim-notify and default)
    if id then
      pcall(vim.notify, "", vim.log.levels.INFO, { replace = id, title = "octo-ai" })
    end
  end
end

--- Show the accept/reject/refine float for comment refinement.
--- @param original string Original comment
--- @param refined string AI-refined comment
--- @param on_accept fun(text: string) Called with accepted text
--- @param on_refine fun(feedback: string) Called to re-prompt with feedback
function M.refine_float(original, refined, on_accept, on_refine)
  local lines = {}
  table.insert(lines, "── Original ──")
  for _, l in ipairs(vim.split(original, "\n")) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  table.insert(lines, "── AI Refined ──")
  for _, l in ipairs(vim.split(refined, "\n")) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  table.insert(lines, "─────────────────────────────────────")
  table.insert(lines, "  a = accept  |  x = reject  |  r = refine")

  M.open_float("Comment Refine", lines, {
    ft = "markdown",
    on_key = {
      a = function(_, winid)
        vim.api.nvim_win_close(winid, true)
        on_accept(refined)
      end,
      x = function(_, winid)
        vim.api.nvim_win_close(winid, true)
        vim.notify("AI refinement rejected", vim.log.levels.INFO)
      end,
      r = function(_, winid)
        vim.api.nvim_win_close(winid, true)
        M.input("Refinement feedback", on_refine)
      end,
    },
  })
end

return M
