if exists('g:loaded_nvim_mcp') | finish | endif
let g:loaded_nvim_mcp = 1

lua vim.schedule(function() require('nvim-mcp')._schedule_setup() end)
