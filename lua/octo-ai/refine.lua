local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

local _skip_refine = false

local function get_comment_at_cursor()
  local ok, utils = pcall(require, "octo.utils")
  if not ok then
    return nil
  end

  local buffer = utils.get_current_buffer()
  if not buffer then
    return nil
  end

  local comment = buffer:get_comment_at_cursor()
  if not comment then
    return nil
  end

  return {
    body = comment.body or "",
    start_line = comment.bufferStartLine,
    end_line = comment.bufferEndLine,
    bufnr = vim.api.nvim_get_current_buf(),
  }
end

local function get_diff_context()
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

  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer and buffer:isPullRequest() then
      local diff = vim.fn.system({ "gh", "pr", "diff", tostring(buffer.number), "--repo", buffer.repo })
      if vim.v.shell_error == 0 then
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

function M.refine_comment(feedback)
  local comment_info = get_comment_at_cursor()
  if not comment_info then
    vim.notify("No comment at cursor", vim.log.levels.WARN)
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
      vim.notify("Comment refined — saving...", vim.log.levels.INFO)
      -- Save with skip flag so we don't intercept again
      _skip_refine = true
      vim.api.nvim_buf_call(comment_info.bufnr, function()
        vim.cmd("write")
      end)
    end, function(new_feedback)
      M.refine_comment(new_feedback)
    end)
  end)
end

--- Wrap octo.save_buffer to intercept saves on comment buffers.
function M.setup_auto_refine(_)
  local octo = require("octo")
  local original_save = octo.save_buffer

  octo.save_buffer = function(...)
    -- Pass through if skip flag is set
    if _skip_refine then
      _skip_refine = false
      return original_save(...)
    end

    -- Only intercept on comment buffers (ft=octo, bt=acwrite)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype ~= "octo" or vim.bo[bufnr].buftype ~= "acwrite" then
      return original_save(...)
    end

    -- Check if there's a dirty comment worth refining
    local ok, utils = pcall(require, "octo.utils")
    if not ok then
      return original_save(...)
    end

    local buffer = utils.get_current_buffer()
    if not buffer then
      return original_save(...)
    end

    local comment = buffer:get_comment_at_cursor()
    if not comment or vim.trim(comment.body or "") == "" then
      return original_save(...)
    end

    -- Intercept: refine first
    M.refine_comment()
  end
end

return M
