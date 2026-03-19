local M = {}

--- Run claude -p with the given prompt. Returns the response text.
--- Runs asynchronously via jobstart to avoid blocking the UI.
--- @param prompt string The prompt to send
--- @param callback fun(result: string|nil, err: string|nil)
function M.ask(prompt, callback)
  local config = require("octo-ai").config
  local cmd = { config.claude_cmd, "-p", prompt }
  local stdout_chunks = {}
  local stderr_chunks = {}

  vim.fn.jobstart(cmd, {
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
          local err = table.concat(stderr_chunks, "\n")
          callback(nil, "Claude failed (exit " .. code .. "): " .. err)
          return
        end
        local result = vim.trim(table.concat(stdout_chunks, "\n"))
        callback(result)
      end)
    end,
  })
end

--- Build a prompt for comment refinement/enrichment.
--- @param comment_body string The user's draft comment
--- @param diff_context string The surrounding diff hunk
--- @param file_content string|nil The full file content for reference
--- @return string
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

--- Build a prompt for contextual diff questions.
--- @param question string The user's question
--- @param hunk string The diff hunk
--- @param file_path string The file path
--- @param file_content string|nil Full file content
--- @return string
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

--- Build a prompt for PR-level questions.
--- @param question string The user's question
--- @param diff string The full PR diff
--- @return string
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
