local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

--- Get the diff hunk and file path for the current cursor position in a review diff buffer.
--- @return { hunk: string, path: string, file_content: string|nil }|nil
local function get_diff_context()
  local bufnr = vim.api.nvim_get_current_buf()

  local ok, props = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_diff_props")
  if not ok then
    vim.notify("Not in an Octo diff buffer", vim.log.levels.WARN)
    return nil
  end

  local path = props.path or "unknown"

  -- Try to get the current review and file entry for full context
  local review_ok, reviews = pcall(require, "octo.reviews")
  local hunk_lines = {}
  local file_content = nil

  if review_ok then
    local current_review = reviews.get_current_review()
    if current_review and current_review.layout then
      local file = current_review.layout:get_current_file()
      if file then
        -- Get the right-side (new) content as file context
        if file.right_lines then
          file_content = table.concat(file.right_lines, "\n")
        end

        -- Get visible buffer lines as hunk context
        local win = vim.api.nvim_get_current_win()
        local top = vim.fn.line("w0", win)
        local bot = vim.fn.line("w$", win)
        local lines = vim.api.nvim_buf_get_lines(bufnr, top - 1, bot, false)
        hunk_lines = lines
      end
    end
  end

  -- If we couldn't get hunk from review, use visual selection or visible lines
  if #hunk_lines == 0 then
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" then
      local start_line = vim.fn.line("v")
      local end_line = vim.fn.line(".")
      if start_line > end_line then
        start_line, end_line = end_line, start_line
      end
      hunk_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    else
      -- Use surrounding 20 lines as context
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

--- Prompt the user for a question about the current diff context, send to Claude.
function M.prompt_diff()
  local context = get_diff_context()
  if not context then
    return
  end

  ui.input("Ask about this code", function(question)
    local prompt = claude.build_diff_prompt(question, context.hunk, context.path, context.file_content)
    local dismiss = ui.spinner("Asking Claude")

    claude.ask(prompt, function(result, err)
      dismiss()
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      local lines = vim.split(result, "\n")
      ui.open_float("AI Response — " .. context.path, lines, {
        ft = "markdown",
        on_key = {
          c = function(_, winid)
            vim.api.nvim_win_close(winid, true)
            M._post_as_comment(result)
          end,
        },
      })
    end)
  end)
end

--- Post text as a review comment at the current position.
--- Uses Octo's commands if in a review, otherwise copies to clipboard.
--- @param text string
function M._post_as_comment(text)
  local ok, commands = pcall(require, "octo.commands")
  if ok and commands.add_pr_issue_or_review_thread_comment then
    -- Try to use Octo's comment creation with the AI text
    -- This is best-effort — Octo expects interactive comment creation
    vim.fn.setreg("+", text)
    vim.notify("AI response copied to clipboard. Use 'cc' to create a comment and paste.", vim.log.levels.INFO)
  else
    vim.fn.setreg("+", text)
    vim.notify("AI response copied to clipboard", vim.log.levels.INFO)
  end
end

return M
