vim.g.mapleader = " "

local keymap = vim.keymap

keymap.set("n", "<leader>nh", ":nohl<CR>", { desc = "Clear search highlights" })
keymap.set("n", "<leader>m", ":Oil<CR>", { desc = "Go to file explorer" })

-- Comment toggle: Cmd+/ (ghostty direct) with Ctrl+/ fallback (works in tmux/ssh)
keymap.set("n", "<D-/>", "gcc", { remap = true, desc = "Toggle comment" })
keymap.set("v", "<D-/>", "gc", { remap = true, desc = "Toggle comment" })
keymap.set("n", "<C-/>", "gcc", { remap = true, desc = "Toggle comment" })
keymap.set("v", "<C-/>", "gc", { remap = true, desc = "Toggle comment" })

