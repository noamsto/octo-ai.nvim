local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

local MAX_CONTEXT_CHARS = 8000

local function get_comment_at_cursor()
  local ok, utils = pcall(require, "octo.utils")
  if not ok then
    return nil
  end

  local buffer = utils.get_current_buffer()
  if not buffer then
    return nil
  end

  -- Sync buffer text → metadata so body reflects current edits
  buffer:update_metadata()

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

--- Get diff context, calling callback(context_string) when ready.
--- Uses review layout if available (sync), falls back to async `gh pr diff`.
local function get_diff_context(callback)
  local rok, reviews = pcall(require, "octo.reviews")
  if rok then
    local review = reviews.get_current_review()
    if review and review.layout then
      local file = review.layout:get_current_file()
      if file and file.right_lines then
        local content = table.concat(file.right_lines, "\n")
        if #content > MAX_CONTEXT_CHARS then
          content = content:sub(1, MAX_CONTEXT_CHARS) .. "\n... (truncated)"
        end
        callback(content)
        return
      end
    end
  end

  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer and buffer:isPullRequest() then
      local stdout_chunks = {}
      local job_id = vim.fn.jobstart({ "gh", "pr", "diff", tostring(buffer.number), "--repo", buffer.repo }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
          if data then vim.list_extend(stdout_chunks, data) end
        end,
        on_exit = function(_, code)
          vim.schedule(function()
            if code == 0 then
              local diff = vim.trim(table.concat(stdout_chunks, "\n"))
              if #diff > MAX_CONTEXT_CHARS then
                diff = diff:sub(1, MAX_CONTEXT_CHARS) .. "\n... (truncated)"
              end
              callback(diff)
            else
              callback("")
            end
          end)
        end,
      })
      if job_id > 0 then return end
    end
  end

  callback("")
end

local function replace_comment_body(info, new_body)
  if not vim.api.nvim_buf_is_valid(info.bufnr) then
    vim.notify("Comment buffer no longer exists", vim.log.levels.WARN)
    return false
  end
  -- Re-fetch comment position in case the buffer was edited
  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer then
      local comment = buffer:get_comment_at_cursor()
      if comment then
        info.start_line = comment.bufferStartLine
        info.end_line = comment.bufferEndLine
      end
    end
  end
  local lines = vim.split(new_body, "\n")
  vim.bo[info.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(info.bufnr, info.start_line, info.end_line + 1, false, lines)
  return true
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

  local dismiss = ui.spinner("Refining comment")

  get_diff_context(function(diff_context)
    local prompt = claude.build_refine_prompt(comment_info.body, diff_context, nil)

    if feedback then
      prompt = prompt .. "\n\n## Reviewer feedback on previous refinement\n" .. feedback
    end

    claude.ask(prompt, function(result, err)
      dismiss()
      if err then
        vim.notify(err, vim.log.levels.ERROR)
        return
      end

      ui.refine_float(comment_info.body, result, function(accepted_text)
        if not replace_comment_body(comment_info, accepted_text) then return end
        vim.notify("Comment refined — saving...", vim.log.levels.INFO)
        -- Buffer-local skip flag so we don't intercept this save
        vim.b[comment_info.bufnr]._octo_ai_skip_refine = true
        vim.api.nvim_buf_call(comment_info.bufnr, function()
          vim.cmd("write")
        end)
      end, function(new_feedback)
        M.refine_comment(new_feedback)
      end)
    end)
  end)
end

--- Wrap octo.save_buffer to intercept saves on comment buffers.
function M.setup_auto_refine()
  local octo = require("octo")
  local original_save = octo.save_buffer

  octo.save_buffer = function(...)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Pass through if buffer-local skip flag is set
    if vim.b[bufnr]._octo_ai_skip_refine then
      vim.b[bufnr]._octo_ai_skip_refine = false
      return original_save(...)
    end

    -- Only intercept on comment buffers (ft=octo, bt=acwrite)
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

    -- Sync buffer text → metadata so body reflects current edits
    buffer:update_metadata()

    local comment = buffer:get_comment_at_cursor()
    if not comment or vim.trim(comment.body or "") == "" then
      return original_save(...)
    end

    -- Intercept: refine first
    M.refine_comment()
  end
end

return M
