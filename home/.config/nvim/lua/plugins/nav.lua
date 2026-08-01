return {
	{
		"stevearc/oil.nvim",
		opts = { view_options = { show_hidden = true } },
		keys = { { "<leader>m", "<cmd>Oil<cr>", desc = "File Browser" } },
		dependencies = { { "echasnovski/mini.icons", opts = {} } },
		-- dependencies = { "nvim-tree/nvim-web-devicons" }, -- use if you prefer nvim-web-devicons
		-- Lazy loading is not recommended because it is very tricky to make it work correctly in all situations.
		lazy = false,
	},
	{
		"folke/snacks.nvim",
		priority = 1000,
		lazy = false,
		opts = {
			picker = { enabled = true },
			notifier = { enabled = true },
			input = { enabled = true },
		},
		keys = {
			{
				"<leader>ff",
				function()
          Snacks.picker.files({ hidden = true })
				end,
				desc = "Find Files",
			},
			{
				"<leader>fs",
				function()
          Snacks.picker.grep({ hidden = true })
				end,
				desc = "Search Text",
			},
			{
				"<leader>fb",
				function()
					Snacks.picker.buffers()
				end,
				desc = "Buffers",
			},
			{
				"gd",
				function()
					Snacks.picker.lsp_definitions()
				end,
				desc = "Goto Definition",
			},
		},
	},
}
