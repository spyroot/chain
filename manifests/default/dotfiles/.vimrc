call plug#begin()

" Shorthand notation; fetches https://github.com/junegunn/vim-easy-align
" Plug 'junegunn/vim-easy-align'

" Any valid git URL is allowed
" Plug 'https://github.com/junegunn/vim-github-dashboard.git'

" Multiple Plug commands can be written in a single line using | separators
" Plug 'SirVer/ultisnips' | Plug 'honza/vim-snippets'

" On-demand loading
" Plug 'preservim/nerdtree', { 'on': 'NERDTreeToggle' }
" Plug 'tpope/vim-fireplace', { 'for': 'clojure' }

" Using a non-default branch
" Plug 'rdnetto/YCM-Generator', { 'branch': 'stable' }

" Using a tagged release; wildcard allowed (requires git 1.9.2 or above)
" Plug 'fatih/vim-go', { 'tag': '*' }

" Plugin options
" Plug 'nsf/gocode', { 'tag': 'v.20150303', 'rtp': 'vim' }

" Plugin outside ~/.vim/plugged with post-update hook
" Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }

" Unmanaged plugin (manually installed and updated)
" Plug '~/my-prototype-plugin'

Plug 'cocopon/iceberg.vim'
Plug 'ycm-core/YouCompleteMe'
Plug 'Chiel92/vim-autoformat'
Plug 'vim-syntastic/syntastic'
Plug 'maralla/validator.vim'
Plug 'ycm-core/YouCompleteMe'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'pixelneo/vim-python-docstring'
Plug 'cocopon/pgmnt.vim'
Plug 'ekalinin/Dockerfile.vim'

call plug#end()
" You can revert the settings after the call like so:
"   filetype indent off   " Disable file-type-specific indentation
"   syntax off            " Disable syntax highlighting
"
"

colorscheme iceberg
let g:ycm_server_keep_logfiles = 1
let g:ycm_server_log_level = 'debug'

autocmd FileType yaml Autoformat
autocmd FileType json Autoformat

autocmd FileType yaml let b:autoformat_autoindent=1
autocmd FileType yaml let b:autoformat_retab=1
autocmd FileType yaml let b:autoformat_remove_trailing_spaces=1

autocmd FileType json let b:autoformat_autoindent=1
autocmd FileType json let b:autoformat_retab=1
autocmd FileType json let b:autoformat_remove_trailing_spaces=1

