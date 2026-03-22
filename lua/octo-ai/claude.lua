local M = {}

--- Run claude -p with the given prompt via stdin.
--- @param prompt string The prompt to send
--- @param callback fun(result: string|nil, err: string|nil)
function M.ask(prompt, callback)
  local config = require("octo-ai").config
  local cmd = { config.claude_cmd, "-p" }
  vim.list_extend(cmd, config.claude_args or {})

  local stdout_chunks = {}
  local stderr_chunks = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr_chunks, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local err = vim.trim(table.concat(stderr_chunks, "\n"))
          local out = vim.trim(table.concat(stdout_chunks, "\n"))
          local msg = err ~= "" and err or out
          callback(nil, "Claude failed (exit " .. code .. "): " .. msg)
          return
        end
        local result = vim.trim(table.concat(stdout_chunks, "\n"))
        callback(result)
      end)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start claude command (is '" .. config.claude_cmd .. "' on PATH?)")
    return nil
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")

  return job_id
end

function M.build_refine_prompt(comment_body, diff_context, file_content)
  local parts = {
    "You are a code review assistant. Refine and enrich the following PR review comment.",
    "",
    "Guidelines:",
    "- Improve clarity and precision",
    "- Add specific file/line references where helpful",
    "- Include brief code examples if they strengthen the point",
    "- Keep the reviewer's intent and tone",
    "- Keep it concise — don't add fluff",
    "- Return ONLY the improved comment text, no meta-commentary",
    "",
    "## Diff context",
    "```",
    diff_context,
    "```",
  }

  if file_content then
    table.insert(parts, "")
    table.insert(parts, "## Full file content")
    table.insert(parts, "```")
    table.insert(parts, file_content)
    table.insert(parts, "```")
  end

  table.insert(parts, "")
  table.insert(parts, "## Original comment")
  table.insert(parts, comment_body)

  return table.concat(parts, "\n")
end

function M.build_diff_prompt(question, hunk, file_path, file_content)
  local parts = {
    "You are a code review assistant. Answer the reviewer's question about this code change.",
    "",
    "File: " .. file_path,
    "",
    "## Diff hunk",
    "```",
    hunk,
    "```",
  }

  if file_content then
    table.insert(parts, "")
    table.insert(parts, "## Full file content")
    table.insert(parts, "```")
    table.insert(parts, file_content)
    table.insert(parts, "```")
  end

  table.insert(parts, "")
  table.insert(parts, "## Question")
  table.insert(parts, question)

  return table.concat(parts, "\n")
end

function M.build_pr_prompt(question, diff)
  return table.concat({
    "You are a code review assistant. Answer the reviewer's question about this pull request.",
    "",
    "## PR Diff",
    "```diff",
    diff,
    "```",
    "",
    "## Question",
    question,
  }, "\n")
end

return M
