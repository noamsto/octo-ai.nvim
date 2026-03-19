local M = {}

local defaults = {
  comment_refine = "on-demand", -- "auto" | "on-demand" | "off"
  claude_cmd = "claude",
  claude_args = {}, -- extra args, e.g. {"--model", "sonnet"} or {"--fast"}
  keymaps = {
    refine = "<leader>ar",
    prompt_diff = "<leader>ap",
    prompt_pr = "<leader>aa",
  },
}

M.config = vim.deepcopy(defaults)

local function apply_octo_keymaps(bufnr)
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

local function apply_diff_keymaps(bufnr)
  local km = M.config.keymaps
  local opts = { buffer = bufnr, silent = true }

  vim.keymap.set({ "n", "v" }, km.prompt_diff, function()
    require("octo-ai.prompt").prompt_diff()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about diff" }))

  vim.keymap.set("n", km.prompt_pr, function()
    require("octo-ai.pr").prompt()
  end, vim.tbl_extend("force", opts, { desc = "AI: Ask about PR" }))

  if M.config.comment_refine ~= "off" then
    vim.keymap.set("n", km.refine, function()
      require("octo-ai.refine").refine_comment()
    end, vim.tbl_extend("force", opts, { desc = "AI: Refine comment" }))
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  local group = vim.api.nvim_create_augroup("OctoAI", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "octo", "markdown.gh" },
    callback = function(ev)
      apply_octo_keymaps(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local ok = pcall(vim.api.nvim_buf_get_var, ev.buf, "octo_diff_props")
      if ok then
        apply_diff_keymaps(ev.buf)
      end
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local ft = vim.bo[bufnr].filetype
      if ft == "octo" or ft == "markdown.gh" then
        apply_octo_keymaps(bufnr)
      end
      local ok = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_diff_props")
      if ok then
        apply_diff_keymaps(bufnr)
      end
    end
  end

  if M.config.comment_refine == "auto" then
    require("octo-ai.refine").setup_auto_refine(group)
  end
end

return M
