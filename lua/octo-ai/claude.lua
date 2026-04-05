local M = {}

local active_sessions = {} -- session_name -> UUID

local function generate_uuid()
  local random = math.random
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
    return string.format("%x", v)
  end))
end

--- Run a command asynchronously, collecting stdout.
--- @param cmd string[] Command and arguments
--- @param callback fun(stdout: string|nil, err: string|nil)
function M.run_cmd(cmd, callback)
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
          callback(nil, vim.trim(table.concat(stderr_chunks, "\n")))
          return
        end
        callback(vim.trim(table.concat(stdout_chunks, "\n")))
      end)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start command: " .. cmd[1])
  end
end

--- Truncate a string to max_chars, appending a truncation marker.
--- @param str string
--- @param max_chars number
--- @return string
function M.truncate(str, max_chars)
  if #str > max_chars then
    return str:sub(1, max_chars) .. "\n... (truncated)"
  end
  return str
end

--- Get the current PR context (repo + number) from octo.
--- Tries the active review first, then the current buffer.
--- @param opts? {silent?: boolean}
--- @return {repo: string, number: number}|nil
function M.get_pr_context(opts)
  local rok, reviews = pcall(require, "octo.reviews")
  if rok then
    local review = reviews.get_current_review()
    if review and review.pull_request then
      return { number = review.pull_request.number, repo = review.pull_request.repo }
    end
  end

  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer and buffer:isPullRequest() and buffer.repo then
      return { number = buffer.number, repo = buffer.repo }
    end
  end

  if not (opts and opts.silent) then
    vim.notify("Not in a PR context", vim.log.levels.WARN)
  end
  return nil
end

--- Run claude -p with the given prompt via stdin.
--- @param prompt string The prompt to send
--- @param opts? {session?: string} Options (session: named session to create/resume)
--- @param callback fun(result: string|nil, err: string|nil)
function M.ask(prompt, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = {}
  end
  opts = opts or {}

  local config = require("octo-ai").config
  local cmd = { config.claude_cmd, "-p" }
  local is_new_session = false

  if opts.session then
    local session_id = active_sessions[opts.session]
    if session_id then
      vim.list_extend(cmd, { "-r", session_id })
    else
      is_new_session = true
      session_id = generate_uuid()
      active_sessions[opts.session] = session_id
      vim.list_extend(cmd, { "--session-id", session_id, "-n", opts.session })
    end
  end

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
          if is_new_session then
            active_sessions[opts.session] = nil
          end
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
    "- Use short paragraphs and line breaks for readability — avoid walls of text",
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

local session_cache = {} -- scope_key -> last resolved session name

--- Resolve a review session name, fetching HEAD SHA to detect PR updates.
--- Calls callback(session_name) with a name like "review: repo#42 @abc1234".
--- If the SHA changed since last call, the old session is automatically invalidated.
--- @param repo string e.g. "owner/repo"
--- @param number number PR number
--- @param suffix? string optional scope (e.g. file path, "refine")
--- @param callback fun(session: string)
function M.resolve_session(repo, number, suffix, callback)
  local scope_key = repo .. "#" .. number
  if suffix then
    scope_key = scope_key .. "-" .. suffix
  end

  M.run_cmd(
    { "gh", "pr", "view", tostring(number), "--repo", repo, "--json", "headRefOid", "-q", ".headRefOid" },
    function(sha)
      local name = "review: " .. repo .. "#" .. number
      if suffix then
        name = name .. " — " .. suffix
      end

      if sha and sha ~= "" then
        name = name .. " @" .. sha:sub(1, 7)
      end

      local old_name = session_cache[scope_key]
      if old_name and old_name ~= name then
        active_sessions[old_name] = nil
      end
      session_cache[scope_key] = name

      callback(name)
    end
  )
end

--- Forget a session so the next ask() creates a fresh one.
function M.clear_session(name)
  active_sessions[name] = nil
end

return M
