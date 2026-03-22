local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

local MAX_CONTEXT_CHARS = 8000

local function resolve_refine_session(callback)
  local ctx = claude.get_pr_context({ silent = true })
  if ctx then
    claude.resolve_session(ctx.repo, ctx.number, "refine", callback)
  else
    callback(nil)
  end
end

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
        callback(claude.truncate(table.concat(file.right_lines, "\n"), MAX_CONTEXT_CHARS))
        return
      end
    end
  end

  local ctx = claude.get_pr_context({ silent = true })
  if ctx then
    claude.run_cmd({ "gh", "pr", "diff", tostring(ctx.number), "--repo", ctx.repo }, function(stdout)
      callback(stdout and claude.truncate(stdout, MAX_CONTEXT_CHARS) or "")
    end)
    return
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

function M.refine_comment(feedback, session)
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

  local function do_refine(sess)
    get_diff_context(function(diff_context)
      local prompt
      if feedback and sess then
        prompt = "Refine the comment again based on this feedback:\n" .. feedback
      else
        prompt = claude.build_refine_prompt(comment_info.body, diff_context, nil)
        if feedback then
          prompt = prompt .. "\n\n## Reviewer feedback on previous refinement\n" .. feedback
        end
      end

      claude.ask(prompt, { session = sess }, function(result, err)
        dismiss()
        if err then
          vim.notify(err, vim.log.levels.ERROR)
          return
        end

        ui.refine_float(comment_info.body, result, function(accepted_text)
          if not replace_comment_body(comment_info, accepted_text) then return end
          if not vim.api.nvim_buf_is_valid(comment_info.bufnr) then return end
          vim.notify("Comment refined — saving...", vim.log.levels.INFO)
          vim.b[comment_info.bufnr]._octo_ai_skip_refine = true
          vim.api.nvim_buf_call(comment_info.bufnr, function()
            vim.cmd("write")
          end)
        end, function(new_feedback)
          M.refine_comment(new_feedback, sess)
        end)
      end)
    end)
  end

  if session then
    do_refine(session)
  else
    resolve_refine_session(do_refine)
  end
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
