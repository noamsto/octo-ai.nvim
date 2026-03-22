local claude = require("octo-ai.claude")
local ui = require("octo-ai.ui")

local M = {}

local MAX_DIFF_CHARS = 30000

local PRESETS = {
  { label = "Review — find bugs and issues", prompt = "Review this PR for bugs, logic errors, security issues, and code quality. Be specific with file and line references." },
  { label = "Summarize — what does this PR do", prompt = "Summarize this pull request. What is the purpose, what changed, and what are the key decisions?" },
  { label = "Find bugs — security and correctness", prompt = "Focus on finding bugs, edge cases, race conditions, and security vulnerabilities in this PR." },
  { label = "Custom question...", prompt = nil },
}

local function get_pr_context()
  local ok, utils = pcall(require, "octo.utils")
  if ok then
    local buffer = utils.get_current_buffer()
    if buffer and buffer:isPullRequest() then
      return { number = buffer.number, repo = buffer.repo }
    end
  end

  local rok, reviews = pcall(require, "octo.reviews")
  if rok then
    local review = reviews.get_current_review()
    if review then
      return { number = review.pull_request.number, repo = review.repo }
    end
  end

  vim.notify("Not in a PR context", vim.log.levels.WARN)
  return nil
end

--- Fetch PR diff asynchronously to avoid blocking the UI.
local function get_pr_diff_async(number, repo, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}

  local job_id = vim.fn.jobstart({ "gh", "pr", "diff", tostring(number), "--repo", repo }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then vim.list_extend(stdout_chunks, data) end
    end,
    on_stderr = function(_, data)
      if data then vim.list_extend(stderr_chunks, data) end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          callback(nil, "Failed to get PR diff: " .. vim.trim(table.concat(stderr_chunks, "\n")))
          return
        end
        local diff = vim.trim(table.concat(stdout_chunks, "\n"))
        if #diff > MAX_DIFF_CHARS then
          diff = diff:sub(1, MAX_DIFF_CHARS) .. "\n... (truncated)"
        end
        callback(diff)
      end)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start 'gh' command")
  end
end

function M.prompt()
  local ctx = get_pr_context()
  if not ctx then
    return
  end

  vim.ui.select(PRESETS, {
    prompt = "AI: Ask about PR #" .. ctx.number,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end

    local function run_prompt(question)
      local dismiss = ui.spinner("Claude is reviewing PR #" .. ctx.number)

      get_pr_diff_async(ctx.number, ctx.repo, function(diff, err)
        if err or not diff then
          dismiss()
          vim.notify(err or "Failed to get PR diff", vim.log.levels.ERROR)
          return
        end

        local prompt = claude.build_pr_prompt(question, diff)
        claude.ask(prompt, function(result, ask_err)
          dismiss()
          if ask_err then
            vim.notify(ask_err, vim.log.levels.ERROR)
            return
          end

          local lines = vim.split(result, "\n")
          ui.open_float("AI — PR #" .. ctx.number, lines, {
            ft = "markdown",
            keys = {
              f = {
                desc = "followup",
                fn = function(_, winid)
                  vim.api.nvim_win_close(winid, true)
                  ui.input("Follow-up question", function(followup)
                    run_prompt(followup)
                  end)
                end,
              },
            },
          })
        end)
      end)
    end

    if choice.prompt then
      run_prompt(choice.prompt)
    else
      ui.input("Ask about PR #" .. ctx.number, run_prompt)
    end
  end)
end

return M
