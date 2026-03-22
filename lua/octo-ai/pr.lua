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

local function get_pr_diff_async(number, repo, callback)
  claude.run_cmd({ "gh", "pr", "diff", tostring(number), "--repo", repo }, function(stdout, err)
    if err then
      callback(nil, "Failed to get PR diff: " .. err)
      return
    end
    callback(claude.truncate(stdout, MAX_DIFF_CHARS))
  end)
end

function M.prompt()
  local ctx = claude.get_pr_context()
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

    claude.resolve_session(ctx.repo, ctx.number, nil, function(session)
      local is_followup = false

      local function run_prompt(question)
        local dismiss = ui.spinner("Claude is reviewing PR #" .. ctx.number)

        local function send(prompt)
          claude.ask(prompt, { session = session }, function(result, ask_err)
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
                      is_followup = true
                      run_prompt(followup)
                    end)
                  end,
                },
              },
            })
          end)
        end

        if is_followup then
          send(question)
          return
        end

        get_pr_diff_async(ctx.number, ctx.repo, function(diff, err)
          if err or not diff then
            dismiss()
            vim.notify(err or "Failed to get PR diff", vim.log.levels.ERROR)
            return
          end
          send(claude.build_pr_prompt(question, diff))
        end)
      end

      if choice.prompt then
        run_prompt(choice.prompt)
      else
        ui.input("Ask about PR #" .. ctx.number, run_prompt)
      end
    end)
  end)
end

return M
