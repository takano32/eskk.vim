" vim:foldmethod=marker:fen:
scriptencoding utf-8

" See 'plugin/eskk.vim' about the license.

" Saving 'cpoptions' {{{
let s:save_cpo = &cpo
set cpo&vim
" }}}

runtime! plugin/eskk.vim

" Variables {{{
let s:sticky_key_char = ''
let s:henkan_key_char = ''

" Current mode.
let s:eskk_mode = ''
" Supported modes.
let s:available_modes = []
" Buffer strings for inserted, filtered and so on.
let s:buftable = eskk#buftable#new()
" }}}

" Write timestamp to debug file {{{
if g:eskk_debug && exists('g:eskk_debug_file') && filereadable(expand(g:eskk_debug_file))
    call writefile(['', printf('--- %s ---', strftime('%c')), ''], expand(g:eskk_debug_file))
endif
" }}}

" FIXME
" 1. Enable lang mode
" 2. Leave insert mode
" 3. Enter insert mode.
" Lang mode is still enabled.
"
" TODO
" - Trap CursorMovedI and
" -- s:buftable.reset()
" -- rewrite current displayed string.

" Functions {{{

" Initialize/Mappings
function! s:is_skip_key(key) "{{{
    let char = eskk#util#eval_key(a:key)

    return eskk#is_henkan_key(char)
    \   || eskk#is_sticky_key(char)
    \   || maparg(char, 'l') ==? '<plug>(eskk-enable)'
    \   || maparg(char, 'l') ==? '<plug>(eskk-disable)'
    \   || maparg(char, 'l') ==? '<plug>(eskk-toggle)'
endfunction "}}}
function! eskk#map_key(key) "{{{
    " Assumption: a:key must be '<Bar>' not '|'.

    if s:is_skip_key(a:key)
        return
    endif

    " Save current a:key mapping
    "
    " TODO Check if a:key is buffer local.
    " Because if it is not buffer local,
    " there is no necessity to stash current a:key.
    " if maparg(a:key, 'l') != ''
    "     execute
    "     \   'lnoremap'
    "     \   s:stash_lang_key_map(a:key)
    "     \   maparg(a:key, 'l')
    " endif

    " Map a:key.
    let named_key = s:map_named_key(a:key)
    execute
    \   'lmap'
    \   a:key
    \   named_key
endfunction "}}}
function! eskk#unmap_key(key) "{{{
    " Assumption: a:key must be '<Bar>' not '|'.

    if s:is_skip_key(a:key)
        return
    endif

    " Unmap a:key.
    execute
    \   'lunmap'
    \   a:key

    " TODO Restore buffer local mapping.

endfunction "}}}
function! s:stash_lang_key_map(key) "{{{
    return printf('<Plug>(eskk:prevmap:%s)', a:key)
endfunction "}}}
function! s:map_named_key(key) "{{{
    " NOTE:
    " a:key is escaped. So when a:key is '<C-a>', return value is
    "   `<Plug>(eskk:filter:<C-a>)`
    " not
    "   `<Plug>(eskk:filter:^A)` (^A is control character)

    let lhs = printf('<Plug>(eskk:filter:%s)', a:key)
    if maparg(lhs, 'l') != ''
        return lhs
    endif

    execute
    \   'lnoremap'
    \   '<expr><silent>'
    \   lhs
    \   printf('eskk#filter_key(%s)', string(a:key))
    execute
    \   'noremap!'
    \   '<expr><silent>'
    \   lhs
    \   printf('eskk#filter_key(%s)', string(a:key))

    return lhs
endfunction "}}}

function! eskk#default_mapped_keys() "{{{
    return split(
    \   'abcdefghijklmnopqrstuvwxyz'
    \  .'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    \  .'1234567890'
    \  .'!"#$%&''()'
    \  .',./;:]@[-^\'
    \  .'>?_+*}`{=~'
    \   ,
    \   '\zs'
    \) + [
    \   "<lt>",
    \   "<Bar>",
    \   "<Tab>",
    \   "<BS>",
    \   "<C-h>",
    \]
endfunction "}}}



" Utility functions
function! s:get_mode_func(func_str) "{{{
    return printf('eskk#mode#%s#%s', eskk#get_mode(), a:func_str)
endfunction "}}}



" Enable/Disable IM
function! eskk#is_enabled() "{{{
    return &iminsert == 1
endfunction "}}}
function! eskk#enable() "{{{
    if eskk#is_enabled()
        return ''
    endif
    call eskk#util#log('enabling eskk...')

    " Clear current variable states.
    let s:eskk_mode = ''
    call s:buftable.reset()

    " Set up Mappings.
    for key in g:eskk_mapped_key
        call eskk#map_key(key)
    endfor

    " TODO Save previous mode/state.
    call eskk#set_mode(g:eskk_initial_mode)

    call eskk#util#call_if_exists(s:get_mode_func('cb_im_enter'), [], 'no throw')
    return "\<C-^>"
endfunction "}}}
function! eskk#disable() "{{{
    if !eskk#is_enabled()
        return ''
    endif
    call eskk#util#log('disabling eskk...')

    for key in g:eskk_mapped_key
        call eskk#unmap_key(key)
    endfor

    call eskk#util#call_if_exists(s:get_mode_func('cb_im_leave'), [], 'no throw')
    return "\<C-^>"
endfunction "}}}
function! eskk#toggle() "{{{
    if eskk#is_enabled()
        return eskk#disable()
    else
        return eskk#enable()
    endif
endfunction "}}}

" Sticky key
function! eskk#get_sticky_char() "{{{
    if s:sticky_key_char != ''
        return s:sticky_key_char
    endif

    redir => output
    silent lmap
    redir END

    for line in split(output, '\n')
        let info = eskk#util#parse_map(line)
        if info.rhs ==? '<plug>(eskk-sticky-key)'
            let s:sticky_key_char = info.lhs
            return s:sticky_key_char
        endif
    endfor

    call eskk#util#log('failed to get sticky character...')
    return ''
endfunction "}}}
function! eskk#sticky_key(again, stash) "{{{
    call eskk#util#log("<Plug>(eskk-sticky-key)")

    if !a:again
        return eskk#filter_key(eskk#get_sticky_char())
    else
        if s:step_henkan_phase(s:buftable)
            call eskk#util#logf("Succeeded to step to next henkan phase. (current: %d)", s:buftable.get_henkan_phase())
            return s:buftable.get_current_marker()
        else
            call eskk#util#logf("Failed to step to next henkan phase. (current: %d)", s:buftable.get_henkan_phase())
            return ''
        endif
    endif
endfunction "}}}
function! s:step_henkan_phase(buftable) "{{{
    let phase   = a:buftable.get_henkan_phase()
    let buf_str = a:buftable.get_current_buf_str()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        call a:buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_HENKAN)
        return 1    " stepped.
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
        if buf_str.get_rom_str() != '' || buf_str.get_filter_str() != ''
            call a:buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_OKURI)
            return 1    " stepped.
        else
            return 0    " failed.
        endif
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI
        return 0    " failed.
    else
        throw eskk#internal_error(['eskk'])
    endif
endfunction "}}}
function! eskk#is_sticky_key(char) "{{{
    return maparg(a:char, 'l') ==? '<plug>(eskk-sticky-key)'
endfunction "}}}

" Henkan key
function! eskk#henkan_key(again, stash) "{{{
    call eskk#util#log("<Plug>(eskk-henkan-key)")

    if !a:again
        return eskk#filter_key(eskk#get_henkan_key())
    else
    endif
endfunction "}}}
function! eskk#get_henkan_key() "{{{
    if s:henkan_key_char != ''
        return s:henkan_key_char
    endif

    redir => output
    silent lmap
    redir END

    for line in split(output, '\n')
        let info = eskk#util#parse_map(line)
        if info.rhs ==? '<plug>(eskk-henkan-key)'
            let s:henkan_key_char = info.lhs
            return s:henkan_key_char
        endif
    endfor

    call eskk#util#log('failed to get henkan character...')
    return ''
endfunction "}}}
function! eskk#is_henkan_key(char) "{{{
    return maparg(a:char, 'l') ==? '<plug>(eskk-henkan-key)'
endfunction "}}}

" Big letter keys
function! eskk#is_big_letter(char) "{{{
    return a:char =~# '^[A-Z]$'
endfunction "}}}

" Mode
function! eskk#set_mode(next_mode) "{{{
    if !eskk#is_supported_mode(a:next_mode)
        call eskk#util#warnf("mode '%s' is not supported.", a:next_mode)
        return
    endif

    call eskk#util#call_if_exists(
    \   s:get_mode_func('cb_mode_leave'),
    \   [a:next_mode],
    \   "no throw"
    \)

    let prev_mode = s:eskk_mode
    let s:eskk_mode = a:next_mode

    call s:buftable.reset()

    call eskk#util#call_if_exists(
    \   s:get_mode_func('cb_mode_enter'),
    \   [prev_mode],
    \   "no throw"
    \)

    " For &statusline.
    redrawstatus
endfunction "}}}
function! eskk#get_mode() "{{{
    return s:eskk_mode
endfunction "}}}
function! eskk#is_supported_mode(mode) "{{{
    return !empty(filter(copy(s:available_modes), 'v:val ==# a:mode'))
endfunction "}}}
function! eskk#register_mode(mode) "{{{
    call add(s:available_modes, a:mode)
    let fmt = 'lnoremap <expr> <Plug>(eskk-mode-to-%s) eskk#set_mode(%s)'
    execute printf(fmt, a:mode, string(a:mode))
endfunction "}}}
function! eskk#get_registered_modes() "{{{
    return s:available_modes
endfunction "}}}



" Dispatch functions
function! eskk#filter_key(char) "{{{
    call eskk#util#logf('a:char = %s(%d)', a:char, char2nr(a:char))
    if !eskk#is_supported_mode(s:eskk_mode)
        call eskk#util#warn('current mode is empty!')
        sleep 1
    endif

    let opt = {
    \   'redispatch_chars': [],
    \   'return': 0,
    \   'finalize_fn': [],
    \}
    let filter_args = [{
    \   'char': a:char,
    \   'option': opt,
    \   'buftable': s:buftable,
    \}]
    call s:buftable.set_old_str(s:buftable.get_display_str())

    try
        let let_me_handle = call(s:get_mode_func('cb_handle_key'), filter_args)
        call eskk#util#log('current mode handles key:'.let_me_handle)

        if !let_me_handle && eskk#has_default_filter(a:char)
            call eskk#util#log('calling eskk#default_filter()...')
            call call('eskk#default_filter', filter_args)
        else
            call eskk#util#log('calling filter function...')
            call call(s:get_mode_func('filter'), filter_args)
        endif

        if type(opt.return) == type("")
            return opt.return
        else
            let str = s:buftable.rewrite()
            let rest = join(map(opt.redispatch_chars, 'eskk#filter_key(v:val)'), '')
            return str . rest
        endif

    catch
        " TODO Show v:exception only once in current mode.
        "
        " sleep 1
        "
        call eskk#util#warn('!!!!!!!!!!!!!! error !!!!!!!!!!!!!!')
        call eskk#util#warn('--- exception ---')
        call eskk#util#warnf('v:exception: %s', v:exception)
        call eskk#util#warnf('v:throwpoint: %s', v:throwpoint)
        call eskk#util#warn('--- buftable ---')
        for phase in s:buftable.get_all_phases()
            let buf_str = s:buftable.get_buf_str(phase)
            call eskk#util#warnf('phase:%d', phase)
            call eskk#util#warnf('pos: %s', string(buf_str.get_pos()))
            call eskk#util#warnf('rom_str: %s', buf_str.get_rom_str())
            call eskk#util#warnf('filter_str: %s', buf_str.get_filter_str())
        endfor
        call eskk#util#warn('--- char ---')
        call eskk#util#warnf('char: %s', a:char)
        call eskk#util#warn('!!!!!!!!!!!!!! error !!!!!!!!!!!!!!')

        call s:buftable.reset()
        return a:char

    finally
        for Fn in opt.finalize_fn
            call call(Fn, [])
        endfor
    endtry
endfunction "}}}
function! eskk#has_default_filter(char) "{{{
    let maparg = tolower(maparg(a:char, 'l'))
    return a:char ==# "\<BS>"
    \   || a:char ==# "\<C-h>"
    \   || a:char ==# "\<CR>"
    \   || eskk#is_henkan_key(a:char)
    \   || eskk#is_sticky_key(a:char)
    \   || eskk#is_big_letter(a:char)
endfunction "}}}
function! eskk#default_filter(stash) "{{{
    call eskk#util#log('eskk#default_filter()')

    let char = a:stash.char
    " TODO Changing priority?

    if char ==# "\<BS>" || char ==# "\<C-h>"
        call s:do_backspace(a:stash)
    elseif char ==# "\<CR>"
        call s:do_enter(a:stash)
    elseif eskk#is_henkan_key(char)
        return eskk#henkan_key(1, a:stash)
    elseif eskk#is_sticky_key(char)
        return eskk#sticky_key(1, a:stash)
    elseif eskk#is_big_letter(char)
        return eskk#sticky_key(1, a:stash)
        \    . eskk#filter_key(tolower(char))
    else
        let a:stash.option.return = a:stash.char
    endif
endfunction "}}}
function! s:do_backspace(stash) "{{{
    let [opt, buftable] = [a:stash.option, a:stash.buftable]
    if buftable.get_old_str() == ''
        let opt.return = "\<BS>"
    else
        " Build backspaces to delete previous characters.
        for buf_str in buftable.get_lower_buf_str()
            if buf_str.get_rom_str() != ''
                call buf_str.pop_rom_str()
                break
            elseif buf_str.get_filter_str() != ''
                call buf_str.pop_filter_str()
                break
            endif
        endfor
    endif
endfunction "}}}
function! s:do_enter(stash) "{{{
    let buftable = a:stash.buftable
    let phase = buftable.get_henkan_phase()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        call buftable.reset()
    else
        throw eskk#not_implemented_error(['eskk'])
    endif
endfunction "}}}



" Errors
function! s:build_error(from, msg) "{{{
    return join(a:from, ': ') . ' - ' . join(a:msg, ': ')
endfunction "}}}

function! eskk#internal_error(from, ...) "{{{
    return s:build_error(a:from, ['internal error'] + a:000)
endfunction "}}}
function! eskk#not_implemented_error(from, ...) "{{{
    return s:build_error(a:from, ['not implemented'] + a:000)
endfunction "}}}
function! eskk#never_reached_error(from, ...) "{{{
    return s:build_error(a:from, ['this block will be never reached'] + a:000)
endfunction "}}}
function! eskk#out_of_idx_error(from, ...) "{{{
    return s:build_error(a:from, ['out of index'] + a:000)
endfunction "}}}
function! eskk#parse_error(from, ...) "{{{
    return s:build_error(a:from, ['parse error'] + a:000)
endfunction "}}}
function! eskk#assertion_failure_error(from, ...) "{{{
    " This is only used from eskk#util#assert().
    return s:build_error(a:from, ['assertion failed'] + a:000)
endfunction "}}}
function! eskk#user_error(from, msg) "{{{
    " Return simple message.
    " TODO Omit a:from to simplify message?
    return printf('%s: %s', join(a:from, ': '), a:msg)
endfunction "}}}
" }}}


" Auto commands {{{
augroup eskk
    autocmd!
    autocmd InsertLeave * call s:buftable.reset()
augroup END
" }}}


" Restore 'cpoptions' {{{
let &cpo = s:save_cpo
" }}}
