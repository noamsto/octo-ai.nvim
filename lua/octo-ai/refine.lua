local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

--- Get the comment body at cursor from an Octo buffer.
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

--- Get diff context — tries review diff first, then gh pr diff.
local function get_diff_context()
  -- Try current review diff (when in review mode)
  local rok, reviews = pcall(require, "octo.reviews")
  if rok then
    local review = reviews.get_current_review()
    if review and review.layout then
      local file = review.layout:get_current_file()
      if file and file.right_lines then
        return table.concat(file.right_lines, "\n")
      end
    end
  end

  -- Fall back to gh pr diff
  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer and buffer:isPullRequest() then
      local diff = vim.fn.system({ "gh", "pr", "diff", tostring(buffer.number), "--repo", buffer.repo })
      if vim.v.shell_error == 0 then
        -- Truncate large diffs
        if #diff > 8000 then
          diff = diff:sub(1, 8000) .. "\n... (truncated)"
        end
        return diff
      end
    end
  end

  return ""
end

local function replace_comment_body(info, new_body)
  local lines = vim.split(new_body, "\n")
  vim.bo[info.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(info.bufnr, info.start_line, info.end_line + 1, false, lines)
end

--- Refine the comment at cursor.
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
      M.refine_comment(new_feedback)
    end)
  end)
end

function M.setup_auto_refine(augroup)
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    pattern = "octo://*",
    callback = function()
      local ok, utils = pcall(require, "octo.utils")
      if not ok then
        return
      end

      local buffer = utils.get_current_buffer()
      if not buffer then
        return
      end

      local comment = buffer:get_comment_at_cursor()
      if not comment or not comment.dirty then
        return
      end

      vim.schedule(function()
        M.refine_comment()
      end)
    end,
  })
end

return M
