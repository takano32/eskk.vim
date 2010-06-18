" vim:foldmethod=marker:fen:
scriptencoding utf-8

" See 'plugin/eskk.vim' about the license.

" Load once {{{
if exists('s:loaded')
    finish
endif
let s:loaded = 1
" }}}
" Saving 'cpoptions' {{{
let s:save_cpo = &cpo
set cpo&vim
" }}}
runtime! plugin/eskk.vim


function! s:SID() "{{{
    return matchstr(expand('<sfile>'), '<SNR>\zs\d\+\ze_SID$')
endfunction "}}}
let s:SID_PREFIX = s:SID()
delfunc s:SID

let s:stash = eskk#get_mutable_stash(['mode', 'builtin'])

" Common {{{
call s:stash.init('current_table', {})

function! eskk#mode#builtin#set_table(table_name) "{{{
    call eskk#util#logf("Set '%s' table to s:current_table.", a:table_name)
    call s:stash.set('current_table', s:[a:table_name])
endfunction "}}}
" }}}

" Asymmetric built-in modes. {{{

" Variables {{{
" Local between instances.
let s:rom_to_hira   = eskk#table#new('rom_to_hira')
let s:rom_to_kata   = eskk#table#new('rom_to_kata')

call s:stash.init('skk_dict', eskk#dictionary#new([
\   extend(deepcopy(g:eskk_dictionary), {'is_user_dict': 1}),
\   g:eskk_large_dictionary,
\]))
call s:stash.init('current_henkan_result', {})
" }}}



function! eskk#mode#builtin#do_q_key(stash) "{{{
    let buf_str = a:stash.buftable.get_current_buf_str()
    let phase = a:stash.buftable.get_henkan_phase()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        " Toggle current table.
        call eskk#set_mode(eskk#get_mode() ==# 'hira' ? 'kata' : 'hira')
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
    \   || phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI

        let normal_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_NORMAL)
        let henkan_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN)
        let okuri_buf_str  = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)

        let filter_str = henkan_buf_str.get_filter_str()

        call henkan_buf_str.clear()
        call okuri_buf_str.clear()

        call a:stash.buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)

        let table = (s:stash.get('current_table') is s:rom_to_hira ? s:get_table_lazy('hira_to_kata') : s:get_table_lazy('kata_to_hira'))
        for wchar in split(filter_str, '\zs')
            call normal_buf_str.push_filter_str(table.get_map_to(wchar, wchar))
        endfor

        function! s:finalize()
            let buftable = eskk#get_buftable()
            if buftable.get_henkan_phase() ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
                let buf_str = buftable.get_current_buf_str()
                call buf_str.clear_filter_str()
            endif
        endfunction

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('finalize', s:SID_PREFIX),
        \   []
        \)
    else
        throw eskk#internal_error(['eskk', 'mode', 'hira'])
    endif
endfunction "}}}
function! s:get_table_lazy(table_name) "{{{
    let varname = 's:' . a:table_name
    if exists(varname)
        return {varname}
    else
        let {varname} = eskk#table#new(a:table_name)
        return {varname}
    endif
endfunction "}}}

function! eskk#mode#builtin#do_lmap_non_egg_like_newline(do_map) "{{{
    if a:do_map
        if !eskk#has_temp_key('<CR>')
            call eskk#util#log("Map *non* egg like newline...: <CR> => <Plug>(eskk:filter:<CR>)<Plug>(eskk:filter:<CR>)")
            call eskk#set_up_temp_key('<CR>', '<Plug>(eskk:filter:<CR>)<Plug>(eskk:filter:<CR>)')
        endif
    else
        call eskk#util#log("Restore *non* egg like newline...: <CR>")
        call eskk#register_temp_event('filter-begin', 'eskk#set_up_temp_key_restore', ['<CR>'])
    endif
endfunction "}}}

function! eskk#mode#builtin#update_dictionary() "{{{
    call s:stash.get('skk_dict').update_dictionary()
endfunction "}}}

function! s:do_backspace(stash) "{{{
    let [opt, buftable] = [a:stash.option, a:stash.buftable]
    if buftable.get_old_str() == ''
        let opt.return = "\<BS>"
        return
    endif

    let phase = buftable.get_henkan_phase()
    if phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT
        " Pretend skk.vim behavior.
        " Enter normal phase and delete one character.
        call buftable.move_buf_str(
        \   g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT,
        \   g:eskk#buftable#HENKAN_PHASE_NORMAL
        \)
        call a:stash.buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)
        let normal_buf_str = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_NORMAL)
        call normal_buf_str.pop_filter_str()
        return
    endif

    " Build backspaces to delete previous characters.
    for phase in buftable.get_lower_phases()
        let buf_str = buftable.get_buf_str(phase)
        if buf_str.get_rom_str() != ''
            call buf_str.pop_rom_str()
            break
        elseif buf_str.get_filter_str() != ''
            call buf_str.pop_filter_str()
            break
        elseif buftable.get_marker(phase) != ''
            if !buftable.step_back_henkan_phase()
                let msg = "Normal phase's marker is empty, "
                \       . "and other phases *should* be able to change "
                \       . "current henkan phase."
                throw eskk#internal_error(['eskk'], msg)
            endif
            break
        endif
    endfor
endfunction "}}}
function! s:do_enter_finalize() "{{{
    if eskk#get_buftable().get_henkan_phase() ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        let buf_str = eskk#get_buftable().get_current_buf_str()
        call buf_str.clear_filter_str()
    endif
endfunction "}}}
function! s:do_enter(stash) "{{{
    call eskk#util#log("s:do_enter()")

    let buftable = a:stash.buftable
    let normal_buf_str        = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_NORMAL)
    let henkan_buf_str        = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN)
    let okuri_buf_str         = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)
    let henkan_select_buf_str = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT)
    let phase = buftable.get_henkan_phase()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        let a:stash.option.return = "\<CR>"
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
        call buftable.move_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN, g:eskk#buftable#HENKAN_PHASE_NORMAL)

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('do_enter_finalize', s:SID_PREFIX),
        \   []
        \)

        call buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI
        call buftable.move_buf_str([g:eskk#buftable#HENKAN_PHASE_HENKAN, g:eskk#buftable#HENKAN_PHASE_OKURI], g:eskk#buftable#HENKAN_PHASE_NORMAL)

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('do_enter_finalize', s:SID_PREFIX),
        \   []
        \)

        call buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT
        call buftable.move_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT, g:eskk#buftable#HENKAN_PHASE_NORMAL)

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('do_enter_finalize', s:SID_PREFIX),
        \   []
        \)

        call buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)
    else
        throw eskk#internal_error(['eskk'])
    endif
endfunction "}}}
function! s:henkan_key(stash) "{{{
    call eskk#util#log('henkan!')

    let phase = a:stash.buftable.get_henkan_phase()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
    \ || phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI
        if g:eskk_kata_convert_to_hira_at_henkan && eskk#get_mode() ==# 'kata'
            let table = s:get_table_lazy('kata_to_hira')
            let henkan_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN)
            let filter_str = henkan_buf_str.get_filter_str()
            call henkan_buf_str.clear_filter_str()
            for wchar in split(filter_str, '\zs')
                call henkan_buf_str.push_filter_str(table.get_map_to(wchar, wchar))
            endfor
            let okuri_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)
            let filter_str = okuri_buf_str.get_filter_str()
            call okuri_buf_str.clear_filter_str()
            for wchar in split(filter_str, '\zs')
                call okuri_buf_str.push_filter_str(table.get_map_to(wchar, wchar))
            endfor
        endif

        let s:current_henkan_result = s:stash.get('skk_dict').refer(a:stash.buftable)

        " Enter henkan select phase.
        call a:stash.buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT)

        " Clear phase henkan/okuri buffer string.
        " Assumption: `s:stash.get('skk_dict').refer()` saves necessary strings.
        let henkan_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN)
        call henkan_buf_str.clear_rom_str()
        call henkan_buf_str.clear_filter_str()
        let okuri_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)
        call okuri_buf_str.clear_rom_str()
        call okuri_buf_str.clear_filter_str()

        let buf_str = a:stash.buftable.get_current_buf_str()
        let candidate = s:current_henkan_result.get_candidate()

        if type(candidate) == type("")
            " Set candidate.
            call buf_str.set_filter_str(candidate)
        else
            " No candidates.
            let input = s:stash.get('skk_dict').register_word(s:current_henkan_result)
            call buf_str.set_filter_str(input)
        endif
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT
        throw eskk#internal_error(['eskk', 'mode', 'builtin'])
    else
        let msg = printf("s:henkan_key() does not support phase %d.", phase)
        throw eskk#internal_error(['eskk', 'mode', 'hira'], msg)
    endif
endfunction "}}}
function! s:get_next_candidate(stash, next) "{{{
    let cur_buf_str = a:stash.buftable.get_current_buf_str()
    if s:current_henkan_result[a:next ? 'advance' : 'back']()
        let candidate = s:current_henkan_result.get_candidate()
        call eskk#util#assert(type(candidate) == type(""))

        " Set candidate.
        call cur_buf_str.set_filter_str(candidate)
    else
        " No more candidates.
        if a:next
            " Register new word when it advanced or backed current result index,
            " And tried to step at last candidates but failed.
            let input = s:stash.get('skk_dict').register_word(s:current_henkan_result)
            call cur_buf_str.set_filter_str(input)
        else
            " Restore previous buftable state: "■書く" => "▽か*k"

            let buftable = s:current_henkan_result._buftable

            let okuri_buf_str = buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)
            if okuri_buf_str.get_rom_str() != ''
                call okuri_buf_str.set_rom_str(okuri_buf_str.get_rom_str()[0])
                call okuri_buf_str.clear_filter_str()
            endif

            call eskk#set_buftable(buftable)
        endif
    endif
endfunction "}}}
function! s:filter_rom_to_hira(stash) "{{{
    let char = a:stash.char
    let buf_str = a:stash.buftable.get_current_buf_str()
    let rom_str = buf_str.get_rom_str() . char

    call eskk#util#logf('mode hira - char = %s, rom_str = %s', string(char), string(rom_str))

    if s:stash.get('current_table').has_map(rom_str)
        " Match!
        call eskk#util#logf('%s - match!', rom_str)
        return s:filter_rom_to_hira_exact_match(a:stash)

    elseif s:stash.get('current_table').has_candidates(rom_str)
        " Has candidates but not match.
        call eskk#util#logf('%s - wait for a next key.', rom_str)
        return s:filter_rom_to_hira_has_candidates(a:stash)

    else
        " No candidates.
        call eskk#util#logf('%s - no candidates.', rom_str)
        return s:filter_rom_to_hira_no_match(a:stash)
    endif
endfunction "}}}
function! s:filter_rom_to_hira_exact_match(stash) "{{{
    let char = a:stash.char
    let buf_str = a:stash.buftable.get_current_buf_str()
    let rom_str = buf_str.get_rom_str() . char
    let phase = a:stash.buftable.get_henkan_phase()

    if phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
    \   || phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
        " Set filtered string.
        call buf_str.push_filter_str(
        \   s:stash.get('current_table').get_map_to(rom_str)
        \)
        call buf_str.clear_rom_str()


        " Set rest string.
        "
        " NOTE:
        " rest must not have multibyte string.
        " rest is for rom string.
        let rest = s:stash.get('current_table').get_rest(rom_str, -1)
        " Assumption: 's:stash.get('current_table').has_map(rest)' returns false here.
        if rest !=# -1
            let a:stash.option.redispatch_chars += split(rest, '\zs')
        endif


        " Clear filtered string when eskk#filter()'s finalizing.
        function! s:finalize()
            let buftable = eskk#get_buftable()
            if buftable.get_henkan_phase() ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
                let buf_str = buftable.get_current_buf_str()
                call buf_str.clear_filter_str()
            endif
        endfunction

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('finalize', s:SID_PREFIX),
        \   []
        \)
    elseif phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI
        " Enter phase henkan select with henkan.

        " Input: "SesSi"
        " Convert from:
        "   henkan buf str:
        "     filter str: "せ"
        "     rom str   : "s"
        "   okuri buf str:
        "     filter str: "し"
        "     rom str   : "si"
        " to:
        "   henkan buf str:
        "     filter str: "せっ"
        "     rom str   : ""
        "   okuri buf str:
        "     filter str: "し"
        "     rom str   : "si"
        " (http://d.hatena.ne.jp/tyru/20100320/eskk_rom_to_hira)
        let henkan_buf_str        = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN)
        let okuri_buf_str         = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_OKURI)
        let henkan_select_buf_str = a:stash.buftable.get_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT)
        let henkan_rom = henkan_buf_str.get_rom_str()
        let okuri_rom  = okuri_buf_str.get_rom_str()
        if henkan_rom != '' && s:stash.get('current_table').has_map(henkan_rom . okuri_rom[0])
            " Push "っ".
            call henkan_buf_str.push_filter_str(
            \   s:stash.get('current_table').get_map_to(henkan_rom . okuri_rom[0])
            \)
            " Push "s" to rom str.
            let rest = s:stash.get('current_table').get_rest(henkan_rom . okuri_rom[0], -1)
            if rest !=# -1
                call okuri_buf_str.set_rom_str(
                \   rest . okuri_rom[1:]
                \)
            endif
        endif

        call eskk#util#assert(char != '')
        call okuri_buf_str.push_rom_str(char)

        if s:stash.get('current_table').has_map(okuri_buf_str.get_rom_str())
            call okuri_buf_str.push_filter_str(
            \   s:stash.get('current_table').get_map_to(okuri_buf_str.get_rom_str())
            \)
            let rest = s:stash.get('current_table').get_rest(okuri_buf_str.get_rom_str(), -1)
            if rest !=# -1
                let a:stash.option.redispatch_chars += split(rest, '\zs')
            endif
        endif

        call s:henkan_key(a:stash)
    endif
endfunction "}}}
function! s:filter_rom_to_hira_has_candidates(stash) "{{{
    let char = a:stash.char
    let buf_str = a:stash.buftable.get_current_buf_str()

    " NOTE: This will be run in all phases.
    call buf_str.push_rom_str(char)
endfunction "}}}
function! s:filter_rom_to_hira_no_match(stash) "{{{
    let char = a:stash.char
    let buf_str = a:stash.buftable.get_current_buf_str()
    let rom_str = buf_str.get_rom_str() . char

    if rom_str != ''
        call buf_str.pop_rom_str()
    endif
    call buf_str.push_rom_str(char)

    let cur_rom_str = buf_str.get_rom_str()
    if s:stash.get('current_table').has_map(cur_rom_str)
        " Set a:stash.char to ''.
        " I feel this a little bit tricky, though...
        let a:stash.char = ''
        call s:filter_rom_to_hira_exact_match(a:stash)
    elseif s:stash.get('current_table').has_candidates(cur_rom_str)
        " Already pushed char. Nop.
    else
        " Pushed current char but no match,
        " then dispose that char.
        call eskk#util#logf("yet no match. dispose '%s'.", char)

        function! s:finalize()
            let buftable = eskk#get_buftable()
            if buftable.get_henkan_phase() ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
                let buf_str = buftable.get_current_buf_str()
                call buf_str.clear_rom_str()
            endif
        endfunction

        call eskk#register_temp_event(
        \   'filter-finalize',
        \   eskk#util#get_local_func('finalize', s:SID_PREFIX),
        \   []
        \)
    endif
endfunction "}}}



function! eskk#mode#builtin#asym_filter(stash) "{{{
    let char = a:stash.char
    let henkan_phase = a:stash.buftable.get_henkan_phase()


    " In order not to change current buftable old string.
    call eskk#lock_old_str()
    try
        " Handle special char.
        " These characters are handled regardless of current phase.
        if char ==# "\<BS>" || char ==# "\<C-h>"
            call s:do_backspace(a:stash)
            return
        elseif char ==# "\<CR>"
            call s:do_enter(a:stash)
            return
        elseif eskk#is_sticky_key(char)
            call eskk#sticky_key(a:stash)
            return
        elseif eskk#is_big_letter(char)
            call eskk#sticky_key(a:stash)
            call eskk#filter(tolower(char))
            return
        else
            " Fall through.
        endif
    finally
        call eskk#unlock_old_str()
    endtry


    if s:stash.get('current_table') is s:rom_to_hira    " hira
        if eskk#is_special_lhs(char, 'mode:hira:q-key')
            call eskk#mode#builtin#do_q_key(a:stash)
            return
        elseif eskk#is_special_lhs(char, 'mode:hira:to-ascii')
            call eskk#set_mode('ascii')
            return
        elseif eskk#is_special_lhs(char, 'mode:hira:to-zenei')
            call eskk#set_mode('zenei')
            return
        else
            " Fall through.
        endif
    else    " kata
        if eskk#is_special_lhs(char, 'mode:kata:q-key')
            call eskk#mode#builtin#do_q_key(a:stash)
            return
        elseif eskk#is_special_lhs(char, 'mode:kata:to-ascii')
            call eskk#set_mode('ascii')
            return
        elseif eskk#is_special_lhs(char, 'mode:kata:to-zenei')
            call eskk#set_mode('zenei')
            return
        else
            " Fall through.
        endif
    endif


    if henkan_phase ==# g:eskk#buftable#HENKAN_PHASE_NORMAL
        return s:filter_rom_to_hira(a:stash)
    elseif henkan_phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN
        if eskk#is_henkan_key(char)
            return s:henkan_key(a:stash)
            call eskk#util#assert(a:stash.buftable.get_henkan_phase() == g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT)
        else
            return s:filter_rom_to_hira(a:stash)
        endif
    elseif henkan_phase ==# g:eskk#buftable#HENKAN_PHASE_OKURI
        return s:filter_rom_to_hira(a:stash)
    elseif henkan_phase ==# g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT
        if eskk#is_special_lhs(char, 'henkan-select:choose-next')
            return s:get_next_candidate(a:stash, 1)
        elseif eskk#is_special_lhs(char, 'henkan-select:choose-prev')
            return s:get_next_candidate(a:stash, 0)
        else
            call a:stash.buftable.set_henkan_phase(g:eskk#buftable#HENKAN_PHASE_NORMAL)
            " Move henkan select buffer string to normal.
            call a:stash.buftable.move_buf_str(g:eskk#buftable#HENKAN_PHASE_HENKAN_SELECT, g:eskk#buftable#HENKAN_PHASE_NORMAL)

            return s:filter_rom_to_hira(a:stash)
        endif
    else
        let msg = printf("eskk#mode#builtin#asym_filter() does not support phase %d.", phase)
        throw eskk#internal_error(['eskk'], msg)
    endif
endfunction "}}}

" }}}

" Symmetric built-in modes. {{{

" Variables {{{
let s:rom_to_ascii  = {}
let s:rom_to_zenei  = eskk#table#new('rom_to_zenei')
" }}}



function! eskk#mode#builtin#sym_filter(stash) "{{{
    let c = a:stash.char
    if s:stash.get('current_table') is s:rom_to_ascii    " ascii
        if eskk#is_special_lhs(c, 'mode:ascii:to-hira')
            call eskk#set_mode('hira')
        else
            let a:stash.option.return = c
        endif
    else    " zenei
        if eskk#is_special_lhs(c, 'mode:zenei:to-hira')
            call eskk#set_mode('hira')
        elseif s:stash.get('current_table').has_map(c)
            let a:stash.option.return = s:stash.get('current_table').get_map_to(c)
        else
            let a:stash.option.return = c
        endif
    endif
endfunction "}}}

" }}}


" Restore 'cpoptions' {{{
let &cpo = s:save_cpo
" }}}
