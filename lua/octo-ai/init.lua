local M = {}

local defaults = {
  comment_refine = "on-demand", -- "auto" | "on-demand" | "off"
  claude_cmd = "claude",
  keymaps = {
    refine = "<localleader>ar",
    prompt_diff = "<localleader>ap",
    prompt_pr = "<localleader>aa",
  },
}

M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  local group = vim.api.nvim_create_augroup("OctoAI", { clear = true })

  -- Register keymaps on Octo buffers
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "octo",
    callback = function(ev)
      local bufnr = ev.buf
      local km = M.config.keymaps
      local map_opts = { buffer = bufnr, silent = true }

      if M.config.comment_refine ~= "off" then
        vim.keymap.set("n", km.refine, function()
          require("octo-ai.refine").refine_comment()
        end, vim.tbl_extend("force", map_opts, { desc = "AI: Refine comment" }))
      end

      vim.keymap.set("n", km.prompt_pr, function()
        require("octo-ai.pr").prompt()
      end, vim.tbl_extend("force", map_opts, { desc = "AI: Ask about PR" }))
    end,
  })

  -- Register keymaps on diff review buffers
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local bufnr = ev.buf
      local ok, props = pcall(vim.api.nvim_buf_get_var, bufnr, "octo_diff_props")
      if not ok then
        return
      end

      local km = M.config.keymaps
      local map_opts = { buffer = bufnr, silent = true }

      vim.keymap.set({ "n", "v" }, km.prompt_diff, function()
        require("octo-ai.prompt").prompt_diff()
      end, vim.tbl_extend("force", map_opts, { desc = "AI: Ask about diff" }))

      vim.keymap.set("n", km.prompt_pr, function()
        require("octo-ai.pr").prompt()
      end, vim.tbl_extend("force", map_opts, { desc = "AI: Ask about PR" }))
    end,
  })

  -- Auto-refine: intercept comment save
  if M.config.comment_refine == "auto" then
    require("octo-ai.refine").setup_auto_refine(group)
  end
end

return M
