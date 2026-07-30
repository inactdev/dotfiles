return {
	"Shatur/neovim-ayu",
	lazy = false,
	priority = 1000,
	config = function()
		require("ayu").setup({
      mirage = true, -- Use mirage instead of dark for dark background
      terminal = true, -- Let terminal manage its own colors if false
      overrides = {} -- Customize specific highlights
    })
		vim.cmd.colorscheme("ayu-mirage")
	end,
}
