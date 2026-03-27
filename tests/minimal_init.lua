vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
vim.cmd("runtime plugin/plenary.vim")
