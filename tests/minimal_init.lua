vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = table.concat({
	vim.fn.getcwd() .. "/lua/?.lua",
	vim.fn.getcwd() .. "/lua/?/init.lua",
	package.path,
}, ";")

vim.g.mapleader = " "
vim.notify = function() end
