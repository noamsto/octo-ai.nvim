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
  local file_content = nil
  local hunk_lines = {}
  local selection = nil

  -- Visual selection takes priority over viewport context
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local start_line = vim.fn.getpos("v")[2]
    local end_line = vim.fn.getpos(".")[2]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    hunk_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    selection = {
      start_line = start_line,
      end_line = end_line,
      win_id = vim.api.nvim_get_current_win(),
    }
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end

  -- Get file content from review layout; viewport as fallback context
  local review_ok, reviews = pcall(require, "octo.reviews")
  if review_ok then
    local current_review = reviews.get_current_review()
    if current_review and current_review.layout then
      local file = current_review.layout:get_current_file()
      if file then
        if file.right_lines then
          file_content = claude.truncate(table.concat(file.right_lines, "\n"), MAX_CONTENT_CHARS)
        end
        if #hunk_lines == 0 then
          local win = vim.api.nvim_get_current_win()
          local top = vim.fn.line("w0", win)
          local bot = vim.fn.line("w$", win)
          hunk_lines = vim.api.nvim_buf_get_lines(bufnr, top - 1, bot, false)
        end
      end
    end
  end

  if #hunk_lines == 0 then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local start_line = math.max(0, cursor[1] - 10)
    local end_line = math.min(vim.api.nvim_buf_line_count(bufnr), cursor[1] + 10)
    hunk_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  end

  return {
    hunk = table.concat(hunk_lines, "\n"),
    path = path,
    file_content = file_content,
    selection = selection,
  }
end

--- Try to inject text into the active thread buffer's comment body.
local function inject_comment_body(text)
  vim.schedule(function()
    local bufnr = vim.api.nvim_get_current_buf()
    local utils_ok, utils = pcall(require, "octo.utils")
    if not utils_ok then return end

    local buffer = utils.get_current_buffer()
    if not buffer then return end
    buffer:update_metadata()

    local comment = buffer:get_comment_at_cursor()
    if not comment then return end

    local lines = vim.split(text, "\n")
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, comment.bufferStartLine, comment.bufferEndLine + 1, false, lines)
  end)
end

--- Create a review comment or suggestion on the selected lines via octo.
local function create_review_comment(context, text, is_suggestion)
  if not context.selection then return end

  local sel = context.selection
  if not vim.api.nvim_win_is_valid(sel.win_id) then
    vim.notify("Diff window closed", vim.log.levels.WARN)
    return
  end

  -- Always copy to clipboard as fallback
  vim.fn.setreg("+", text)

  vim.api.nvim_set_current_win(sel.win_id)

  local rok, reviews = pcall(require, "octo.reviews")
  if not rok then
    vim.notify("Copied to clipboard — create comment manually", vim.log.levels.INFO)
    return
  end

  local review = reviews.get_current_review()
  if not review then
    vim.notify("No active review — copied to clipboard", vim.log.levels.WARN)
    return
  end

  _G.OctoLastCmdOpts = { line1 = sel.start_line, line2 = sel.end_line }

  local call_ok, call_err = pcall(function()
    review:add_comment(false)
  end)

  _G.OctoLastCmdOpts = nil

  if not call_ok then
    vim.notify("Copied to clipboard — " .. tostring(call_err), vim.log.levels.WARN)
    return
  end

  local body = text
  if is_suggestion then
    body = "```suggestion\n" .. text .. "\n```"
  end

  inject_comment_body(body)
end

--- Show Claude's response in a float with copy/followup/comment/suggest keys.
local function show_response(context, session, result)
  local lines = vim.split(result, "\n")

  local keys = {
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
  }

  if context.selection then
    keys.m = {
      desc = "comment",
      fn = function(_, winid)
        vim.api.nvim_win_close(winid, true)
        create_review_comment(context, result, false)
      end,
    }
    keys.s = {
      desc = "suggest",
      fn = function(_, winid)
        vim.api.nvim_win_close(winid, true)
        local dismiss = ui.spinner("Generating suggestion")
        local prompt = "Based on your analysis above, write the replacement code for the selected lines.\n"
          .. "Return ONLY the code — no markdown fences, no explanation, no line numbers.\n"
          .. "The code must be a drop-in replacement for the original selection."
        claude.ask(prompt, { session = session }, function(suggestion, err)
          dismiss()
          if err then
            vim.notify(err, vim.log.levels.ERROR)
            return
          end
          create_review_comment(context, suggestion, true)
        end)
      end,
    }
  end

  ui.open_float("AI — " .. context.path, lines, {
    ft = "markdown",
    keys = keys,
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
