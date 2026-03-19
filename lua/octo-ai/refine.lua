local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

--- Get the comment body at cursor from an Octo buffer.
--- Returns the text and metadata needed to replace it.
--- @return { body: string, start_line: integer, end_line: integer, bufnr: integer }|nil
local function get_comment_at_cursor()
  local ok, utils = pcall(require, "octo.utils")
  if not ok then
    vim.notify("Octo not available", vim.log.levels.ERROR)
    return nil
  end

  local buffer = utils.get_current_buffer()
  if not buffer then
    vim.notify("Not in an Octo buffer", vim.log.levels.WARN)
    return nil
  end

  local comment = buffer:get_comment_at_cursor()
  if not comment then
    vim.notify("No comment at cursor", vim.log.levels.WARN)
    return nil
  end

  return {
    body = comment.body or "",
    start_line = comment.bufferStartLine,
    end_line = comment.bufferEndLine,
    bufnr = vim.api.nvim_get_current_buf(),
  }
end

--- Get diff context for the current Octo buffer/PR.
--- @return string
local function get_diff_context()
  local ok, utils = pcall(require, "octo.utils")
  if not ok then
    return ""
  end

  local buffer = utils.get_current_buffer()
  if not buffer or not buffer:isPullRequest() then
    return ""
  end

  local pr = buffer:pullRequest()
  local repo = buffer.repo
  local number = buffer.number

  -- Get the diff via gh CLI
  local diff = vim.fn.system({ "gh", "pr", "diff", tostring(number), "--repo", repo })
  if vim.v.shell_error ~= 0 then
    return ""
  end

  -- Truncate if too large (keep first 4000 chars for context)
  if #diff > 4000 then
    diff = diff:sub(1, 4000) .. "\n... (truncated)"
  end

  return diff
end

--- Replace comment body in the Octo buffer.
--- @param info { bufnr: integer, start_line: integer, end_line: integer }
--- @param new_body string
local function replace_comment_body(info, new_body)
  local lines = vim.split(new_body, "\n")
  vim.bo[info.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(info.bufnr, info.start_line, info.end_line + 1, false, lines)
end

--- Refine the comment at cursor.
--- @param feedback string|nil Optional feedback for re-refinement
function M.refine_comment(feedback)
  local comment_info = get_comment_at_cursor()
  if not comment_info then
    return
  end

  if vim.trim(comment_info.body) == "" then
    vim.notify("Comment is empty — write something first", vim.log.levels.WARN)
    return
  end

  local diff_context = get_diff_context()
  local prompt = claude.build_refine_prompt(comment_info.body, diff_context, nil)

  if feedback then
    prompt = prompt .. "\n\n## Reviewer feedback on previous refinement\n" .. feedback
  end

  local dismiss = ui.spinner("Refining comment")

  claude.ask(prompt, function(result, err)
    dismiss()
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    ui.refine_float(comment_info.body, result, function(accepted_text)
      replace_comment_body(comment_info, accepted_text)
      vim.notify("Comment refined", vim.log.levels.INFO)
    end, function(new_feedback)
      -- Re-refine with feedback
      M.refine_comment(new_feedback)
    end)
  end)
end

--- Set up auto-refine: intercept before Octo saves dirty comments.
--- @param augroup integer
function M.setup_auto_refine(augroup)
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    pattern = "octo://*",
    callback = function(ev)
      local ok, utils = pcall(require, "octo.utils")
      if not ok then
        return
      end

      local buffer = utils.get_current_buffer()
      if not buffer then
        return
      end

      -- Check if there are dirty comments
      local comment = buffer:get_comment_at_cursor()
      if not comment or not comment.dirty then
        return
      end

      -- Prevent the save, refine first
      -- The user will save again after accepting
      vim.schedule(function()
        M.refine_comment()
      end)

      -- Return true to prevent the default BufWritePre behavior
      -- Note: this doesn't actually prevent Octo's BufWriteCmd, so we rely on
      -- the user accepting/rejecting before the save completes
    end,
  })
end

return M
