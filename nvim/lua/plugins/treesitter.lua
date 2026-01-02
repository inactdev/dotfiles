return {
	"nvim-treesitter/nvim-treesitter",
	lazy = false,
	build = ":TSUpdate",
	config = function()
		local ts = require("nvim-treesitter")

		-- Install core parsers (add your languages here)
		ts.install({
			"ruby",
			"json",
			"javascript",
			"typescript",
			"tsx",
			"yaml",
			"html",
			"css",
			"markdown",
			"markdown_inline",
			"graphql",
			"bash",
			"lua",
			"vim",
			"dockerfile",
			"gitignore",
			"query",
			"vimdoc",
		}, { summary = false }):wait(30000)

		-- Autocmd to enable Treesitter on file open
		vim.api.nvim_create_autocmd("FileType", {
			group = vim.api.nvim_create_augroup("treesitter_enable", { clear = true }),
			pattern = "*",
			callback = function(event)
				local lang = event.match
				local ok, task = pcall(ts.install, { lang }, { summary = true })
				if ok then
					task:wait(10000)
				end
				pcall(vim.treesitter.start, event.buf, lang)
			end,
		})
	end,
}
