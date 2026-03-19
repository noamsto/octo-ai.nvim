local M = {}

local defaults = {
  comment_refine = "on-demand", -- "auto" | "on-demand" | "off"
  claude_cmd = "claude",
  claude_args = {}, -- extra args, e.g. {"--model", "sonnet"} or {"--fast"}
  keymaps = {
    refine = "<localleader>Ar",
    prompt_diff = "<localleader>Ap",
    prompt_pr = "<localleader>Aa",
  },
}

M.config = vim.deepcopy(defaults)

--- Apply keymaps to comment/thread buffers (ft=octo, bt=acwrite).
local function apply_comment_keymaps(bufnr)
  local km = M.config.keymaps
  local opts = { buffer = bufnr, silent = true }

  if M.config.comment_refine ~= "off" then
    vim.keymap.set("n", km.refine, function()
      require("octo-ai.refine").refine_comment()
    end, vim.tbl_extend("force", opts, { desc = "AI: Refine comment" }))
  end

  vim.keymap.set("n", km.prompt_pr, function()
    require("octo-ai.pr").prompt()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about PR" }))
end

--- Apply keymaps to PR description buffers (ft=markdown.gh).
local function apply_pr_keymaps(bufnr)
  local km = M.config.keymaps
  local opts = { buffer = bufnr, silent = true }

  vim.keymap.set("n", km.prompt_pr, function()
    require("octo-ai.pr").prompt()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about PR" }))
end

--- Apply keymaps to diff review buffers (octo_diff_props set).
local function apply_diff_keymaps(bufnr)
  local km = M.config.keymaps
  local opts = { buffer = bufnr, silent = true }

  vim.keymap.set({ "n", "v" }, km.prompt_diff, function()
    require("octo-ai.prompt").prompt_diff()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about diff" }))

  vim.keymap.set("n", km.prompt_pr, function()
    require("octo-ai.pr").prompt()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about PR" }))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  local group = vim.api.nvim_create_augroup("OctoAI", { clear = true })

  -- Comment/thread buffers: ft=octo or name matches octo://*/threads/*
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "octo",
    callback = function(ev)
      apply_comment_keymaps(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
    group = group,
    pattern = "octo://*/review/*/threads/*",
    callback = function(ev)
      apply_comment_keymaps(ev.buf)
    end,
  })

  -- PR description buffers: ft=markdown.gh
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown.gh",
    callback = function(ev)
      apply_pr_keymaps(ev.buf)
    end,
  })

  -- Diff review buffers: name matches octo://*/review/*/file/*
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost" }, {
    group = group,
    pattern = "octo://*/review/*/file/*",
    callback = function(ev)
      apply_diff_keymaps(ev.buf)
    end,
  })

  -- Apply to already-open buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.bo[bufnr].filetype
      if ft == "octo" then
        apply_comment_keymaps(bufnr)
      elseif ft == "markdown.gh" then
        apply_pr_keymaps(bufnr)
      end
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name:match("^octo://.*/review/.*/file/") then
        apply_diff_keymaps(bufnr)
      end
    end
  end

  if M.config.comment_refine == "auto" then
    require("octo-ai.refine").setup_auto_refine(group)
  end
end

return M
