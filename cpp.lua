
local cpp = {}

local c99 = require("c99")
local inspect = require("inspect")

local SEP = package.config:sub(1,1)

local function debug(...) print(...) end
--local function debug() end

local function gcc_default_defines()
    local pd = io.popen("LANG=C gcc -dM -E - < /dev/null")
    if not pd then
        return {}
    end
    local blank_ctx = {
        incdirs = {},
        defines = {},
        ifmode = { true },
        output = {},
        current_dir = {},
    }
    local ctx = cpp.parse_file("-", pd, blank_ctx)

    ctx.defines["__builtin_va_list"] = { "char", "*" }
    ctx.defines["__extension__"] = {}
    ctx.defines["__attribute__"] = { args = { "arg" }, repl = {} }
    ctx.defines["__restrict"] = { "restrict" }
    ctx.defines["__inline__"] = { "inline" }
    ctx.defines["__inline"] = { "inline" }

    return ctx.defines
end

local function cpp_include_paths()
    local pd = io.popen("LANG=C cpp -v /dev/null -o /dev/null 2>&1")
    if not pd then
        return { quote = {}, system = { "/usr/include"} }
    end
    local res = {
        quote = {},
        system = {},
    }
    local mode = nil
    for line in pd:lines() do
        if line:find([[#include "..." search starts here]], 1, true) then
            mode = "quote"
        elseif line:find([[#include <...> search starts here]], 1, true) then
            mode = "system"
        elseif line:find([[End of search list]], 1, true) then
            mode = nil
        elseif mode then
            table.insert(res[mode], line:sub(2))
        end
    end
    pd:close()
    return res
end

-- TODO default defines: `gcc -dM -E - < /dev/null`

-- Not supported:
-- * character set conversion
-- * trigraphs

local states = {
    any = {
        ['"'] = { next = "dquote" },
        ["'"] = { next = "squote" },
        ["/"] = { silent = true, next = "slash" },
    },
    dquote = {
        ['"'] = { next = "any" },
        ["\\"] = { next = "dquote_backslash" },
    },
    dquote_backslash = {
        single_char = true,
        default = { next = "dquote" },
    },
    squote = {
        ["'"] = { next = "any" },
        ["\\"] = { next = "squote_backslash" },
    },
    squote_backslash = {
        single_char = true,
        default = { next = "squote" },
    },
    slash = {
        single_char = true,
        ["/"] = { add = " ", silent = true, next = "line_comment" },
        ["*"] = { add = " ", silent = true, next = "block_comment" },
        default = { add = "/", next = "any" },
    },
    line_comment = {
        silent = true,
    },
    block_comment = {
        silent = true,
        ["*"] = { silent = true, next = "try_end_block_comment" },
        continue_line = "block_comment",
    },
    try_end_block_comment = {
        single_char = true,
        silent = true,
        ["/"] = { silent = true, next = "any" },
        default = { silent = true, next = "block_comment" },
        continue_line = "block_comment",
    },
}

for _, rules in pairs(states) do
    local out = "["
    for k, _ in pairs(rules) do
        if #k == 1 then
            out = out .. k
        end
    end
    out = out .. "]"
    rules.pattern = out ~= "[]" and out
end

local function add(buf, txt)
    if not buf then
        buf = {}
    end
    table.insert(buf, txt)
    return buf
end

function cpp.initial_processing(fd)
    local backslash_buf
    local buf
    local state = "any"
    local output = {}
    local linenr = 0
    for line in fd:lines() do
        linenr = linenr + 1
        local len = #line
        if line:find("\\", len, true) then
            -- If backslash-terminated, buffer it
            backslash_buf = add(backslash_buf, line:sub(1, len - 1))
        else
            -- Merge backslash-terminated line
            if backslash_buf then
                table.insert(backslash_buf, line)
                line = table.concat(backslash_buf)
            end
            backslash_buf = nil

            len = #line
            local i = 1
            local out = ""
            -- Go through the line
            while i <= len do
                -- Current state in the state machine
                local st = states[state]

                -- Look for next character matching a state transition
                local n = nil
                if st.pattern then
                    if st.single_char then
                        if line:sub(i,i):find(st.pattern) then
                            n = i
                        end
                    else
                        n = line:find(st.pattern, i)
                    end
                end

                local transition, ch
                if n then
                    ch = line:sub(n, n)
                    transition = st[ch]
                else
                    n = i
                    ch = line:sub(n, n)
                    transition = st.default
                end

                if not transition then
                    -- output the rest of the string if we should
                    if not st.silent then
                        out = i == 1 and line or line:sub(i)
                    end
                    break
                end

                -- output everything up to the transition if we should
                if n > i and not st.silent then
                    buf = add(buf, line:sub(i, n - 1))
                end

                -- Some transitions output an explicit character
                if transition.add then
                    buf = add(buf, transition.add)
                end

                if not transition.silent then
                    buf = add(buf, ch)
                end

                -- and move to the next state
                state = transition.next
                i = n + 1
            end

            -- If we ended in a non-line-terminating state
            if states[state].continue_line then
                -- buffer the output and keep going
                buf = add(buf, out)
                state = states[state].continue_line
            else
                -- otherwise, flush the buffer
                if buf then
                    table.insert(buf, out)
                    out = table.concat(buf)
                    buf = nil
                end
                -- output the string and reset the state.
                table.insert(output, { nr = linenr, line = out})
                state = "any"
            end
        end
    end
    return output
end

local function singleton(t)
    return t and type(t) == "table" and next(t) == 1 and next(t, 1) == nil
end

local function remove_wrapping_subtables(t)
    while singleton(t) do
        t = t[1]
    end
    if type(t) == "table" then
        for k, v in pairs(t) do
            t[k] = remove_wrapping_subtables(v)
        end
    end
    return t
end

function cpp.tokenize(line)
    return c99.preprocessing_grammar:match(line)
end

local function find_file(ctx, filename, mode, is_next)
    local paths = {}
    local current_dir = ctx.current_dir[#ctx.current_dir]
    if mode == "quote" or is_next then
        if not is_next then
            table.insert(paths, current_dir)
        end
        for _, incdir in ipairs(ctx.incdirs.quote or {}) do
            table.insert(paths, incdir)
        end
    end
    if mode == "system" or is_next then
        for _, incdir in ipairs(ctx.incdirs.system or {}) do
            table.insert(paths, incdir)
        end
    end
    if is_next then
        while paths[1] and paths[1] ~= current_dir do
            print(paths[1], "VERSUS", current_dir)
            table.remove(paths, 1)
        end
        table.remove(paths, 1)
    end
    for _, path in ipairs(paths) do
        local pathname = path..SEP..filename
        local fd, err = io.open(pathname, "r")
        if fd then
            return pathname, fd
        end
    end
    return nil, nil, "file not found"
end

local function parse_expression(tokens)
    local text = table.concat(tokens, " ")
    local exp, err, rest = c99.preprocessing_expression_grammar:match(text)
    if not exp then
        print("Error parsing expression: ", err, "[[" .. rest:sub(1, 20))
    end
    exp = remove_wrapping_subtables(exp)
    return exp
end

local eval_exp

local function eval_val(ctx, val)
    if type(val) == "table" then
        if     val.op == "+" then return eval_val(ctx, val[1]) + eval_val(ctx, val[2])
        elseif val.op == "-" then return eval_val(ctx, val[1]) - eval_val(ctx, val[2])
        elseif val.op == "*" then return eval_val(ctx, val[1]) * eval_val(ctx, val[2])
        elseif val.op == "/" then return eval_val(ctx, val[1]) / eval_val(ctx, val[2])
        elseif val.op == ">>" then return eval_val(ctx, val[1]) >> eval_val(ctx, val[2]) -- FIXME C semantics
        elseif val.op == "<<" then return eval_val(ctx, val[1]) << eval_val(ctx, val[2]) -- FIXME C semantics
        elseif val.op == "?" then
            if eval_exp(ctx, val[1]) then
                return eval_val(ctx, val[2])
            else
                return eval_val(ctx, val[3])
            end
        else
            error("unimplemented operator " .. tostring(val.op))
        end
    else
        local defined = ctx.defines[val]
        if singleton(defined) and defined[1] ~= val then
            return eval_val(ctx, defined[1])
        end
        return tonumber(val) or 0 -- TODO long numbers etc
    end
end

eval_exp = function(ctx, exp)
debug(inspect(exp))
    if exp.op == "&&" then
        for _, e in ipairs(exp) do
            if not eval_exp(ctx, e) then
                return false
            end
        end
        return true
    elseif exp.op == "||" then
        for _, e in ipairs(exp) do
            if eval_exp(ctx, e) then
                return true
            end
        end
        return false
    elseif exp.op == "!" then
        return not eval_exp(ctx, exp.exp)
    elseif exp.op == "==" then
        return eval_val(ctx, exp[1]) == eval_val(ctx, exp[2])
    elseif exp.op == "!=" then
        return eval_val(ctx, exp[1]) ~= eval_val(ctx, exp[2])
    elseif exp.op == ">=" then
        return eval_val(ctx, exp[1]) >= eval_val(ctx, exp[2])
    elseif exp.op == "<=" then
        return eval_val(ctx, exp[1]) <= eval_val(ctx, exp[2])
    elseif exp.op == ">" then
        return eval_val(ctx, exp[1]) > eval_val(ctx, exp[2])
    elseif exp.op == "<" then
        return eval_val(ctx, exp[1]) < eval_val(ctx, exp[2])
    elseif exp.op == "defined" then
        return ctx.defines[exp.exp] ~= nil
    elseif type(exp) == "string" then
        return eval_val(ctx, exp) ~= 0
    else
        error("unimplemented operator " .. tostring(exp.op))
    end
end

local function consume_parentheses(tokens, start, linelist)
    local args = {}
    local i = start + 1
    local arg = {}
    local stack = 0
    local cur = linelist.cur
    while true do
        local token = tokens[i]
        if token == nil then
            repeat
                cur = cur + 1
                if not linelist[cur] then
                    error("unterminated function-like macro")
                end
                local nextline = linelist[cur].tk
                if singleton(nextline) then
                    nextline = nextline[1]
                end
                linelist[cur].tk = {}
                table.move(nextline, 1, #nextline, i, tokens)
                token = tokens[i]
            until token
        end
        if token == "(" then
            stack = stack + 1
            table.insert(arg, token)
        elseif token == ")" then
            if stack == 0 then
                if #arg > 0 then
                    table.insert(args, arg)
                end
                break
            end
            stack = stack - 1
            table.insert(arg, token)
        elseif token == "," then
            if stack == 0 then
                table.insert(args, arg)
                arg = {}
            else
                table.insert(arg, token)
            end
        else
            table.insert(arg, token)
        end
        i = i + 1
    end
    return args, i
end

local function array_copy(t)
    local t2 = {}
    for i,v in ipairs(t) do
        t2[i] = v
    end
    return t2
end

local function table_remove(list, pos, n)
    table.move(list, pos + n, #list + n, pos)
end

local function is_sequence(list)
    local i = 0
    for _,_ in ipairs(list) do
        i = i + 1
    end
    local p = 0
    for _,_ in pairs(list) do
        p = p + 1
    end
    return i == p
end

local function table_replace_n_with(list, at, n, values)
local old = #list
debug("TRNW?", inspect(list), "AT", at, "N", n, "VALUES", inspect(values))
    assert(is_sequence(list))
    local nvalues = #values
    local nils = n >= nvalues and (n - nvalues + 1) or 0
    if n ~= nvalues then
        table.move(list, at + n, #list + nils, at + nvalues)
    end
debug("....", inspect(list))
    table.move(values, 1, nvalues, at, list)
    assert(is_sequence(list))
debug("TRNW!", inspect(list))
assert(#list == old - n + #values)
end

local function stringify(tokens)
    return '"'..table.concat(tokens, " "):gsub("\"", "\\")..'"'
end

local macro_expand

local function replace_args(ctx, tokens, args)
    local i = 1
    local hash_next = false
    local join_next = false
    while true do
        local token = tokens[i]
        if not token then
            break
        end
        if token == "#" then
            hash_next = true
            table.remove(tokens, i)
        elseif token == "##" then
            join_next = true
            table.remove(tokens, i)
        elseif args[token] then
            macro_expand(ctx, args[token], nil, false) -- FIXME linelist == nil??
            if hash_next then
                tokens[i] = stringify(args[token])
                hash_next = false
            elseif join_next then
                tokens[i - 1] = tokens[i - 1] .. table.concat(args[token], " ")
                table.remove(tokens, i)
                join_next = false
            else
                table_replace_n_with(tokens, i, 1, args[token])
debug(token, inspect(args[token]), inspect(tokens))
                i = i + #args[token]
            end
        elseif join_next then
            tokens[i - 1] = tokens[i - 1] .. tokens[i]
            table.remove(tokens, i)
            join_next = false
        else
            hash_next = false
            join_next = false
            i = i + 1
        end
    end
end

macro_expand = function(ctx, tokens, linelist, expr_mode)
    local i = 1
    while true do
        ::continue::
debug(i, inspect(tokens))
        local token = tokens[i]
        if not token then
            break
        end
        if expr_mode then
            if token == "defined" then
                if tokens[i + 1] == "(" then
                    i = i + 2
                end
                i = i + 2
                goto continue
            end
        end
        local define = ctx.defines[token]
        if define then
debug(token, inspect(define))
            local repl = define.repl
            if define.args then
                if tokens[i + 1] == "(" then
                    local args, j = consume_parentheses(tokens, i + 1, linelist)
debug("args:", #args, inspect(args))
                    local named_args = {}
                    for i = 1, #define.args do
                        named_args[define.args[i]] = args[i] or {}
                    end
                    local expansion = array_copy(repl)
                    replace_args(ctx, expansion, named_args)
                    local nexpansion = #expansion
                    if nexpansion == 0 then
                        table_remove(tokens, i, (j - i + 1))
                    else
                        table_replace_n_with(tokens, i, (j - i + 1), expansion)
                    end
                else
                    i = i + 1
                end
            else
                local ndefine = #define
                if ndefine == 0 then
                    table.remove(tokens, i)
                elseif ndefine == 1 then
                    tokens[i] = define[1]
                else
                    table_replace_n_with(tokens, i, 1, define)
                end
            end
        else
            i = i + 1
        end
    end
end

local function run_expression(ctx, tks, linelist)
    macro_expand(ctx, tks, linelist, true)
    local exp = parse_expression(tks)
debug(inspect(exp))
    return eval_exp(ctx, exp)
end

function cpp.parse_file(filename, fd, ctx)
    if not ctx then
        ctx = {
            incdirs = cpp_include_paths(),
            defines = gcc_default_defines(),
            ifmode = { true },
            output = {},
            current_dir = {}
        }
    end

    local current_dir = filename:gsub("/[^/]*$", "")
    if current_dir == filename then
        current_dir = "."
    end
    table.insert(ctx.current_dir, current_dir)

    local err
    if not fd then
        fd, err = io.open(filename, "rb")
        if not fd then
            return nil, err
        end
    end
    local linelist = cpp.initial_processing(fd)

    for _, lineitem in ipairs(linelist) do
        lineitem.tk = cpp.tokenize(lineitem.line)
    end

    local ifmode = ctx.ifmode
    for i, lineitem in ipairs(linelist) do
        -- local linenr = lineitem.nr
        local line = lineitem.line
        local tk = lineitem.tk
        linelist.cur = i

debug(filename, ifmode[#ifmode], #ifmode, line)

        if #ifmode == 1 and (tk.directive == "elif" or tk.directive == "else" or tk.directive == "endif") then
            return nil, "unexpected directive " .. tk.directive
        end

        if ifmode[#ifmode] == true then

            if tk.directive then
                debug(inspect(tk))
            end

            if tk.directive == "define" then
                if tk.args then
                    ctx.defines[tk.id] = tk
                else
                    ctx.defines[tk.id] = tk.repl
                end
            elseif tk.directive == "undef" then
                ctx.defines[tk.id] = nil
            elseif tk.directive == "ifdef" then
                table.insert(ifmode, (ctx.defines[tk.id] ~= nil))
            elseif tk.directive == "ifndef" then
                table.insert(ifmode, (ctx.defines[tk.id] == nil))
            elseif tk.directive == "if" then
                table.insert(ifmode, run_expression(ctx, tk.exp, linelist))
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = run_expression(ctx, tk.exp, linelist)
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            elseif tk.directive == "include" or tk.directive == "include_next" then
                local name = tk.exp[1]
                local mode = tk.exp.mode
                local is_next = (tk.directive == "include_next")
                local inc_filename, inc_fd, err = find_file(ctx, name, mode, is_next)
                if not inc_filename then
                    return nil, name..":"..err
                end
                cpp.parse_file(inc_filename, inc_fd, ctx)
            else
                local tokens = tk
                if singleton(tk) and type(tk[1]) == "table" then
                    tokens = tk[1]
                end
                macro_expand(ctx, tokens, linelist, false)
                table.insert(ctx.output, table.concat(tokens, " "))
            end
        elseif ifmode[#ifmode] == false then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else" then
                ifmode[#ifmode] = not ifmode[#ifmode]
            elseif tk.directive == "elif" then
                ifmode[#ifmode] = run_expression(ctx, tk.exp)
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        elseif ifmode[#ifmode] == "skip" then
            if tk.directive == "ifdef"
            or tk.directive == "ifndef"
            or tk.directive == "if" then
                table.insert(ifmode, "skip")
            elseif tk.directive == "else"
                or tk.directive == "elif" then
                -- do nothing
            elseif tk.directive == "endif" then
                table.remove(ifmode, #ifmode)
            end
        end
    end

    table.remove(ctx.current_dir)

    return ctx
end

return cpp
