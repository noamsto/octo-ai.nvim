local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

local MAX_CONTENT_CHARS = 8000

local function get_diff_context()
  local bufnr = vim.api.nvim_get_current_buf()

  local ok, props = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_diff_props")
  if not ok then
    vim.notify("Not in an Octo diff buffer", vim.log.levels.WARN)
    return nil
  end

  local path = props.path or "unknown"

  local review_ok, reviews = pcall(require, "octo.reviews")
  local hunk_lines = {}
  local file_content = nil

  if review_ok then
    local current_review = reviews.get_current_review()
    if current_review and current_review.layout then
      local file = current_review.layout:get_current_file()
      if file then
        if file.right_lines then
          file_content = claude.truncate(table.concat(file.right_lines, "\n"), MAX_CONTENT_CHARS)
        end

        local win = vim.api.nvim_get_current_win()
        local top = vim.fn.line("w0", win)
        local bot = vim.fn.line("w$", win)
        hunk_lines = vim.api.nvim_buf_get_lines(bufnr, top - 1, bot, false)
      end
    end
  end

  if #hunk_lines == 0 then
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" then
      -- Capture visual positions before exiting visual mode
      local start_line = vim.fn.getpos("v")[2]
      local end_line = vim.fn.getpos(".")[2]
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      hunk_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    else
      local cursor = vim.api.nvim_win_get_cursor(0)
      local start_line = math.max(0, cursor[1] - 10)
      local end_line = math.min(vim.api.nvim_buf_line_count(bufnr), cursor[1] + 10)
      hunk_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
    end
  end

  return {
    hunk = table.concat(hunk_lines, "\n"),
    path = path,
    file_content = file_content,
  }
end

--- Show Claude's response in a float with copy/followup keys.
local function show_response(context, session, result)
  local lines = vim.split(result, "\n")
  ui.open_float("AI — " .. context.path, lines, {
    ft = "markdown",
    keys = {
      c = {
        desc = "copy",
        fn = function(_, winid)
          vim.fn.setreg("+", result)
          vim.api.nvim_win_close(winid, true)
          vim.notify("Copied to clipboard", vim.log.levels.INFO)
        end,
      },
      f = {
        desc = "followup",
        fn = function(_, winid)
          vim.api.nvim_win_close(winid, true)
          ui.input("Follow-up question", function(followup)
            M.prompt_diff_followup(followup, context, session)
          end)
        end,
      },
    },
  })
end

function M.prompt_diff()
  local context = get_diff_context()
  if not context then
    return
  end

  local function start(session)
    ui.input("Ask about this code", function(question)
      local prompt = claude.build_diff_prompt(question, context.hunk, context.path, context.file_content)
      local dismiss = ui.spinner("Asking Claude")

      claude.ask(prompt, { session = session }, function(result, err)
        dismiss()
        if err then
          vim.notify(err, vim.log.levels.ERROR)
          return
        end
        show_response(context, session, result)
      end)
    end)
  end

  local ctx = claude.get_pr_context({ silent = true })
  if ctx then
    claude.resolve_session(ctx.repo, ctx.number, context.path, start)
  else
    start(nil)
  end
end

--- Run a follow-up question using the existing session (no context rebuild).
function M.prompt_diff_followup(question, context, session)
  local dismiss = ui.spinner("Asking Claude")

  claude.ask(question, { session = session }, function(result, err)
    dismiss()
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    show_response(context, session, result)
  end)
end

return M
