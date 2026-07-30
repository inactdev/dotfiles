local opt = vim.opt

opt.relativenumber = true
opt.number = true

-- tabs and indentation
opt.tabstop = 2
opt.shiftwidth = 2
opt.expandtab = true
opt.autoindent = true

-- search settings
opt.ignorecase = true
opt.smartcase = true

-- appearance
opt.termguicolors = true
opt.background = "dark"
opt.signcolumn = "yes"

-- backspace
opt.backspace = "indent,eol,start" -- makes backspace work as expected

-- clipboard
opt.clipboard = "unnamedplus" -- use system clipboard as default register

-- mouse
opt.mouse = "a"

-- split windows
opt.splitright = true
opt.splitbelow = true
