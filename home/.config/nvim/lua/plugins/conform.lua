return {
	"stevearc/conform.nvim",
	event = { "BufReadPre", "BufNewFile" },
	config = function()
		local conform = require("conform")

		conform.setup({
			formatters_by_ft = {
				-- runs each project's own rubocop via rbenv; nothing to install globally
				ruby = { "rubocop" },

				-- web stack: prettierd (fast daemon), plain prettier as backup
				javascript = { "prettierd", "prettier", stop_after_first = true },
				typescript = { "prettierd", "prettier", stop_after_first = true },
				javascriptreact = { "prettierd", "prettier", stop_after_first = true },
				typescriptreact = { "prettierd", "prettier", stop_after_first = true },
				css = { "prettierd", "prettier", stop_after_first = true },
				html = { "prettierd", "prettier", stop_after_first = true },
				json = { "prettierd", "prettier", stop_after_first = true },
				yaml = { "prettierd", "prettier", stop_after_first = true },
				markdown = { "prettierd", "prettier", stop_after_first = true },

				lua = { "stylua" },
				python = { "ruff_organize_imports", "ruff_format" },
				nix = { "nixfmt" },

				-- toolchain-bundled: work automatically if/when the language is installed
				go = { "gofmt" },
				rust = { "rustfmt" },
				zig = { "zigfmt" },
			},
			format_on_save = {
				timeout_ms = 1000,
				lsp_format = "fallback",
			},
		})

		vim.keymap.set({ "n", "v" }, "<leader>mp", function()
			conform.format({ lsp_format = "fallback", async = true })
		end, { desc = "Format file or range" })
	end,
}
