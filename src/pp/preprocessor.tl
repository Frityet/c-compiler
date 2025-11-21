local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local Span = require("util.span")
local Lexer = require("lexer.lexer")
local token_mod = require("lexer.token")

local type Token = token_mod.Token
local TokenRecord = token_mod.Token
local type TokenKindType = token_mod.TokenKind
local TK_IDENTIFIER: TokenKindType = "identifier"
local TK_NUMBER: TokenKindType = "number"
local TK_STRING: TokenKindType = "string"
local TK_KEYWORD: TokenKindType = "keyword"
local TK_PUNCT: TokenKindType = "punctuator"
local TK_EOF: TokenKindType = "eof"

local record PreprocessConfig
   search_paths: {string}
   defines: {string:string}
   undefs: {string:boolean}
   current_dir: string
   source_path: string | nil
   no_system_paths: boolean | nil
end

local record PreprocessResult
   text: string
   tokens: {Token}
   file_id: integer
end

local trigraphs: {string:string} = {
   ["??="] = "#",
   ["??/"] = "\\",
   ["??'"] = "^",
   ["??("] = "[",
   ["??)"] = "]",
   ["??!"] = "|",
   ["??<"] = "{",
   ["??>"] = "}",
   ["??-"] = "~",
}

local function replace_trigraphs(src: string): string
   return (src:gsub("%?%?.", function(seq: string): string
      local rep = trigraphs[seq]
      if rep then
         return rep
      end
      return seq
   end))
end

local function normalize_newlines(src: string): string
   src = src:gsub("\r\n", "\n")
   src = src:gsub("\r", "\n")
   return src
end

local function splice_lines(src: string, rep: Reporter, file_id: integer): string
   local removed = 0
   local spliced = src:gsub("\\\r?\n", function(): string
      removed = removed + 1
      return ""
   end)
   if removed > 0 then
      local span = Span.new(file_id, 0, 0, 1, 1)
      rep:report(Diagnostic.new("note", string.format("removed %d line splice(s)", removed), span, "PP001"))
   end
   return spliced
end

local record Macro
   name: string
   params: {string} | nil
   is_variadic: boolean
   replacement: {Token}
   is_function: boolean
   built_in: string | nil
end

local record ConditionalState
   skipping: boolean
   branch_taken: boolean
   in_else: boolean
end

local record State
   macros: {string: Macro}
   reporter: Reporter
   search_paths: {string}
   next_file_id: integer
   current_dir: string
   pragma_once: {string:boolean}
   file_paths: {integer:string}
   file_line_adjust: {integer: integer}
   file_name_override: {integer: string}
end

local function make_token(kind: TokenKindType, lexeme: string, span: Span): Token
   return TokenRecord.new(kind, lexeme, span, {}, {})
end

local function text_from_tokens(tokens: {Token}): string
   local parts: {string} = {}
   for i, t in ipairs(tokens) do
      if t.kind == TK_EOF then
         break
      end
      table.insert(parts, t.lexeme)
      local next_tok = tokens[i + 1]
      if next_tok and next_tok.kind ~= TK_PUNCT and t.kind ~= TK_PUNCT then
         table.insert(parts, " ")
      elseif next_tok and t.kind == TK_IDENTIFIER and next_tok.kind == TK_IDENTIFIER then
         table.insert(parts, " ")
      end
   end
   return table.concat(parts)
end

local function lex_single_token(src: string, file_id: integer, reporter: Reporter): Token | nil
   local next_token = Lexer.lex(src, file_id, reporter)
   local tok = next_token()
   return tok
end

local function path_dir(path: string): string
   local dir = path:match("^(.*)/[^/]+$") or "."
   return dir
end

local function define_object_macro(state: State, name: string, replacement: {Token})
   state.macros[name] = {
      name = name,
      params = nil,
      is_variadic = false,
      replacement = replacement,
      is_function = false,
      built_in = nil,
   }
end

local function define_function_macro(state: State, name: string, params: {string}, is_variadic: boolean, replacement: {Token})
   state.macros[name] = {
      name = name,
      params = params,
      is_variadic = is_variadic,
      replacement = replacement,
      is_function = true,
      built_in = nil,
   }
end

local function add_builtin_macros(state: State, file_id: integer)
   define_object_macro(state, "__STDC__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__STDC_VERSION__", { make_token(TK_NUMBER, "199901L", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__STDC_HOSTED__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   -- Target defaults: clang-ish x86_64 macOS
   -- TODO: proper detection, etc
   define_object_macro(state, "__APPLE__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__MACH__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__GNUC__", { make_token(TK_NUMBER, "4", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__GNUC_MINOR__", { make_token(TK_NUMBER, "2", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__GNUC_PATCHLEVEL__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__clang__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__clang_major__", { make_token(TK_NUMBER, "14", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__clang_minor__", { make_token(TK_NUMBER, "0", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__clang_patchlevel__", { make_token(TK_NUMBER, "3", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__llvm__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__x86_64__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__amd64__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "__LP64__", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })
   define_object_macro(state, "_LP64", { make_token(TK_NUMBER, "1", Span.new(file_id, 0, 0, 1, 1)) })

   state.macros["__FILE__"] = {
      name = "__FILE__",
      params = nil,
      is_variadic = false,
      replacement = {},
      is_function = false,
      built_in = "__FILE__",
   }
   state.macros["__LINE__"] = {
      name = "__LINE__",
      params = nil,
      is_variadic = false,
      replacement = {},
      is_function = false,
      built_in = "__LINE__",
   }
   state.macros["__DATE__"] = {
      name = "__DATE__",
      params = nil,
      is_variadic = false,
      replacement = {},
      is_function = false,
      built_in = "__DATE__",
   }
   state.macros["__TIME__"] = {
      name = "__TIME__",
      params = nil,
      is_variadic = false,
      replacement = {},
      is_function = false,
      built_in = "__TIME__",
   }
end

local function make_state(reporter: Reporter, config: PreprocessConfig, file_id: integer): State
   local base_dir = config.current_dir or (config.source_path and path_dir(config.source_path)) or "."
   local search_paths: {string} = {}
   local seen: {string:boolean} = {}
   local function add_path(p: string | nil)
      if p is nil or p == "" then
         return
      end
      if not seen[p] then
         table.insert(search_paths, p)
         seen[p] = true
      end
   end

   add_path(base_dir)
   for _, p in ipairs(config.search_paths or {}) do
      add_path(p)
   end
   -- add common system include roots so standard headers resolve
   if not config.no_system_paths then
      add_path("/usr/local/include")
      add_path("/usr/include")
      add_path("/Library/Developer/CommandLineTools/usr/include")
      add_path("/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include")
      add_path("/Library/Developer/CommandLineTools/usr/lib/clang/14.0.3/include")
      add_path("/Library/Developer/CommandLineTools/usr/lib/clang/14.0.0/include")
      local sdkroot = os.getenv("SDKROOT")
      if sdkroot is string then
         add_path(sdkroot .. "/usr/include")
         add_path(sdkroot .. "/usr/lib/clang")
      end
   end

   local st: State = {
      macros = {},
      reporter = reporter,
      search_paths = search_paths,
      next_file_id = file_id + 1,
      current_dir = base_dir,
      pragma_once = {},
      file_paths = {},
      file_line_adjust = {},
      file_name_override = {},
   }

   add_builtin_macros(st, file_id)

   for name, body in pairs(config.defines or {}) do
      local toks = Lexer.lex_all(body, file_id, reporter)
      define_object_macro(st, name, toks)
   end
   for name, _ in pairs(config.undefs or {}) do
      st.macros[name] = nil
   end

   return st
end

local function clone_token(t: Token): Token
   return TokenRecord.new(t.kind, t.lexeme, t.span, t.leading, t.trailing, t.has_newline)
end

local function stringize(argument_tokens: {Token}, span: Span): Token
   local pieces: {string} = {}
   for i, t in ipairs(argument_tokens) do
      table.insert(pieces, t.lexeme)
      if i < #argument_tokens then
         table.insert(pieces, " ")
      end
   end
   local content = table.concat(pieces)
   local escaped = content:gsub("\\", "\\\\"):gsub("\"", "\\\"")
   local lexeme = "\"" .. escaped .. "\""
   return make_token(TK_STRING, lexeme, span)
end

local function token_paste(lhs: Token | nil, rhs: Token | nil, file_id: integer, reporter: Reporter): {Token}
   if lhs is nil and rhs is nil then
      return {}
   end
   if lhs is nil then
      return { rhs }
   end
   if rhs is nil then
      return { lhs }
   end

   local combined = lhs.lexeme .. rhs.lexeme
   local tok = lex_single_token(combined, file_id, reporter)
   if tok == nil then
      return {}
   end
   return { tok }
end

local function substitute_macro(macro: Macro, call_span: Span, args: {{Token}}, state: State): {Token}
   local out: {Token} = {}
local params: {string} = (macro.params or {}) as {string}
   local arg_map: {string:{Token}} = {}
   if macro.is_function then
      for i, p in ipairs(params) do
         arg_map[p] = args[i] or {}
      end
      if macro.is_variadic then
         arg_map["__VA_ARGS__"] = args[#args] or {}
      end
   end

   local i = 1
   while i <= #macro.replacement do
      local tok = macro.replacement[i]
      if tok.lexeme == "#" and macro.is_function then
         local next_tok = macro.replacement[i + 1]
         if next_tok and next_tok.kind == TK_IDENTIFIER and arg_map[next_tok.lexeme] then
            local arg_tokens = arg_map[next_tok.lexeme]
            table.insert(out, stringize(arg_tokens, call_span))
            i = i + 2
         else
            table.insert(out, clone_token(tok))
            i = i + 1
         end
      elseif tok.lexeme == "##" then
         local lhs = out[#out]
         local rhs = macro.replacement[i + 1]
         if out[#out] then
            out[#out] = nil
         end
         local rhs_tok: Token | nil = nil
         if rhs and rhs.kind == TK_IDENTIFIER and arg_map[rhs.lexeme] then
            local arg_tokens = arg_map[rhs.lexeme]
            if #arg_tokens > 0 then
               rhs_tok = arg_tokens[1]
            end
         elseif rhs then
            rhs_tok = rhs
         end
        local pasted = token_paste(lhs, rhs_tok, call_span.file_id, state.reporter)
         for _, pt in ipairs(pasted) do
            table.insert(out, pt)
         end
         i = i + 2
      elseif tok.kind == TK_IDENTIFIER and arg_map[tok.lexeme] then
         local arg_tokens = arg_map[tok.lexeme]
         for _, atok in ipairs(arg_tokens) do
            table.insert(out, clone_token(atok))
         end
         i = i + 1
      elseif tok.kind == TK_IDENTIFIER and tok.lexeme == "__VA_ARGS__" and macro.is_variadic then
         local arg_tokens = arg_map["__VA_ARGS__"] or {}
         for _, atok in ipairs(arg_tokens) do
            table.insert(out, clone_token(atok))
         end
         i = i + 1
      elseif tok.kind == TK_IDENTIFIER and tok.lexeme == "__FILE__" and macro.built_in == nil then
         table.insert(out, make_token(TK_STRING, "\"" .. tostring(call_span.file_id) .. "\"", call_span))
         i = i + 1
      elseif tok.kind == TK_IDENTIFIER and tok.lexeme == "__LINE__" and macro.built_in == nil then
         table.insert(out, make_token(TK_NUMBER, tostring(call_span.line), call_span))
         i = i + 1
      else
         table.insert(out, clone_token(tok))
         i = i + 1
      end
   end

   return out
end

local function parse_macro_args(tokens: {Token}, idx: integer): {{Token}}, integer
   local args: {{Token}} = {}
   local depth = 0
   local current: {Token} = {}
   idx = idx + 1 -- skip '('
   while idx <= #tokens do
      local t = tokens[idx]
      if t.kind == TK_PUNCT and t.lexeme == "(" then
         depth = depth + 1
         table.insert(current, t)
      elseif t.kind == TK_PUNCT and t.lexeme == ")" then
         if depth == 0 then
            table.insert(args, current)
            return args, idx
         else
            depth = depth - 1
            table.insert(current, t)
         end
      elseif t.kind == TK_PUNCT and t.lexeme == "," and depth == 0 then
         table.insert(args, current)
         current = {}
      else
         table.insert(current, t)
      end
      idx = idx + 1
   end
   return args, idx
end

local function expand_macros(tokens: {Token}, state: State, expanding?: {string:boolean}, skip?: {string:boolean}): {Token}
   local active = expanding or {}
   local out: {Token} = {}
   local i = 1
   local function append_tokens(ts: {Token})
      for _, et in ipairs(ts) do
         out[#out + 1] = et
      end
   end

   while i <= #tokens do
      local t = tokens[i]
      if t.kind == TK_IDENTIFIER and not (skip and skip[t.lexeme]) then
         local macro = state.macros[t.lexeme]
         if macro and not active[t.lexeme] then
            active[t.lexeme] = true
            if macro.is_function then
               local next_tok = tokens[i + 1]
               if next_tok and next_tok.kind == TK_PUNCT and next_tok.lexeme == "(" then
                  local args, end_idx = parse_macro_args(tokens, i + 1)
                  local expanded = substitute_macro(macro, t.span, args, state)
                  local rec = expand_macros(expanded, state, active, skip)
                  append_tokens(rec)
                  i = end_idx + 1
               else
                  out[#out + 1] = t
                  i = i + 1
               end
            else
               local rep = macro.replacement
               if macro.built_in == "__FILE__" then
                  local override = state.file_name_override[t.span.file_id]
                  local path = override or state.file_paths[t.span.file_id]
                  local value = path or tostring(t.span.file_id)
                  rep = { make_token(TK_STRING, string.format("%q", value), t.span) }
               elseif macro.built_in == "__LINE__" then
                  local adj = state.file_line_adjust[t.span.file_id] or 0
                  rep = { make_token(TK_NUMBER, tostring(t.span.line + adj), t.span) }
               elseif macro.built_in == "__DATE__" then
                  rep = { make_token(TK_STRING, os.date("\"%b %d %Y\""), t.span) }
               elseif macro.built_in == "__TIME__" then
                  rep = { make_token(TK_STRING, os.date("\"%H:%M:%S\""), t.span) }
               end
               local cloned: {Token} = {}
               for _, rt in ipairs(rep) do
                  cloned[#cloned + 1] = clone_token(rt)
               end
               local rec = expand_macros(cloned, state, active, skip)
               append_tokens(rec)
               i = i + 1
            end
            active[t.lexeme] = nil
         else
            out[#out + 1] = t
            i = i + 1
         end
      else
         out[#out + 1] = t
         i = i + 1
      end
   end
   return out
end

local function parse_define(tokens: {Token}, state: State)
   -- tokens start at macro name
   if #tokens == 0 then
      return
   end
   local name_tok = tokens[1]
   if name_tok.kind ~= TK_IDENTIFIER then
      return
   end
   local idx = 2
   local is_function = false
   local params: {string} = {}
   local is_variadic = false
   local next_tok = tokens[idx]
   local is_adjacent = false
   if next_tok then
      local ns = next_tok.span
      local ms = name_tok.span
      is_adjacent = ns.file_id == ms.file_id and ns.start_offset == ms.end_offset
   end
   if next_tok and next_tok.kind == TK_PUNCT and next_tok.lexeme == "(" and is_adjacent then
      is_function = true
      idx = idx + 1
      while idx <= #tokens do
         local t = tokens[idx]
         if t.kind == TK_PUNCT and t.lexeme == ")" then
            idx = idx + 1
            break
         elseif t.kind == TK_PUNCT and t.lexeme == "," then
            idx = idx + 1
         elseif t.kind == TK_PUNCT and t.lexeme == "..." then
            is_variadic = true
            table.insert(params, "__VA_ARGS__")
            idx = idx + 1
            if tokens[idx] and tokens[idx].kind == TK_PUNCT and tokens[idx].lexeme == ")" then
               idx = idx + 1
            end
            break
         elseif t.kind == TK_IDENTIFIER then
            table.insert(params, t.lexeme)
            idx = idx + 1
         else
            idx = idx + 1
         end
      end
   end

   local replacement: {Token} = {}
   while idx <= #tokens do
      table.insert(replacement, tokens[idx])
      idx = idx + 1
   end

   if is_function then
      define_function_macro(state, name_tok.lexeme, params, is_variadic, replacement)
   else
      define_object_macro(state, name_tok.lexeme, replacement)
   end
end

local function parse_if_expr(tokens: {Token}, state: State): boolean
   local skip: {string:boolean} = {}
   for i = 1, #tokens do
      local t = tokens[i]
      if t.kind == TK_IDENTIFIER and t.lexeme == "defined" then
         local nxt = tokens[i + 1]
         if nxt and nxt.kind == TK_IDENTIFIER then
            skip[nxt.lexeme] = true
         elseif nxt and nxt.kind == TK_PUNCT and nxt.lexeme == "(" then
            local idtok = tokens[i + 2]
            if idtok and idtok.kind == TK_IDENTIFIER then
               skip[idtok.lexeme] = true
            end
         end
      end
   end

   local expanded = expand_macros(tokens, state, nil, skip)
   local idx = 1
   local expr: function(): integer

   local function peek(): Token | nil
      return expanded[idx]
   end

   local function advance(): Token | nil
      local t = expanded[idx]
      idx = idx + 1
      return t
   end

   local function primary(): integer
      local t = peek()
      if not t then return 0 end
      local tok: Token = t
      if tok.kind == TK_NUMBER then
         advance()
         local num = tonumber(tok.lexeme)
         if num is nil then return 0 end
         return math.floor(num)
      elseif tok.kind == TK_IDENTIFIER then
         if tok.lexeme == "defined" then
            advance()
            local next_tok = peek()
            if next_tok then
               local nt: Token = next_tok
               if nt.kind == TK_IDENTIFIER then
                  advance()
                  return state.macros[nt.lexeme] and 1 or 0
               elseif nt.kind == TK_PUNCT and nt.lexeme == "(" then
                  advance()
                  local id_tok = peek()
                  local val = 0
                  if id_tok then
                     local it: Token = id_tok
                     if it.kind == TK_IDENTIFIER then
                        val = state.macros[it.lexeme] and 1 or 0
                        advance()
                     end
                  end
                  local closing = peek()
                  if closing then
                     local c: Token = closing
                     if c.kind == TK_PUNCT and c.lexeme == ")" then
                        advance()
                     end
                  end
                  return val
               else
                  return 0
               end
            end
            return 0
         else
            advance()
            return 0
         end
      elseif tok.kind == TK_PUNCT and tok.lexeme == "(" then
         advance()
         local v = expr()
         local closing = peek()
         if closing then
            local c: Token = closing
            if c.kind == TK_PUNCT and c.lexeme == ")" then
               advance()
            end
         end
         return v
      end
      advance()
      return 0
   end

   local function unary(): integer
      local t = peek()
      if t then
         local tok: Token = t
         if tok.kind == TK_PUNCT and (tok.lexeme == "!" or tok.lexeme == "-" or tok.lexeme == "+") then
            advance()
            local v = unary()
            if tok.lexeme == "!" then return (v == 0) and 1 or 0 end
            if tok.lexeme == "-" then return -v end
            return v
         end
      end
      return primary()
   end

   local function mul(): integer
      local v = unary()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT then break end
         local op = tok.lexeme
         if op ~= "*" and op ~= "/" and op ~= "%" then break end
         advance()
         local rhs = unary()
         if op == "*" then v = v * rhs
         elseif op == "/" then v = rhs ~= 0 and math.floor(v / rhs) or 0
         else v = rhs ~= 0 and v % rhs or 0 end
      end
      return v
   end

   local function add(): integer
      local v = mul()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT then break end
         local op = tok.lexeme
         if op ~= "+" and op ~= "-" then break end
         advance()
         local rhs = mul()
         if op == "+" then v = v + rhs else v = v - rhs end
      end
      return v
   end

   local function shift(): integer
      local v = add()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT then break end
         local op = tok.lexeme
         if op ~= "<<" and op ~= ">>" then break end
         advance()
         local rhs = add()
         
         if op == "<<" then
            v = v << rhs
         else
            v = v >> rhs
         end
      end
      return v
   end

   local function rel(): integer
      local v = shift()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT then break end
         local op = tok.lexeme
         if op ~= "<" and op ~= ">" and op ~= "<=" and op ~= ">=" then break end
         advance()
         local rhs = shift()
         if op == "<" then v = (v < rhs) and 1 or 0
         elseif op == ">" then v = (v > rhs) and 1 or 0
         elseif op == "<=" then v = (v <= rhs) and 1 or 0
         else v = (v >= rhs) and 1 or 0 end
      end
      return v
   end

   local function eq(): integer
      local v = rel()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT then break end
         local op = tok.lexeme
         if op ~= "==" and op ~= "!=" then break end
         advance()
         local rhs = rel()
         if op == "==" then v = (v == rhs) and 1 or 0 else v = (v ~= rhs) and 1 or 0 end
      end
      return v
   end

   local function band(): integer
      local v = eq()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT or tok.lexeme ~= "&" then break end
         advance()
         local rhs = eq()
         v = v & rhs
      end
      return v
   end

   local function bxor(): integer
      local v = band()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT or tok.lexeme ~= "^" then break end
         advance()
         local rhs = band()
         v = v ~ rhs
      end
      return v
   end

   local function bor(): integer
      local v = bxor()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT or tok.lexeme ~= "|" then break end
         advance()
         local rhs = bxor()
         v = v | rhs
      end
      return v
   end

   local function land(): integer
      local v = bor()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT or tok.lexeme ~= "&&" then break end
         advance()
         local rhs = bor()
         v = (v ~= 0 and rhs ~= 0) and 1 or 0
      end
      return v
   end

   local function lor(): integer
      local v = land()
      while true do
         local t = peek()
         if not t then break end
         local tok: Token = t
         if tok.kind ~= TK_PUNCT or tok.lexeme ~= "||" then break end
         advance()
         local rhs = land()
         v = (v ~= 0 or rhs ~= 0) and 1 or 0
      end
      return v
   end
   expr = lor
   return expr() ~= 0
end

local function read_file(path: string): string | nil, string | nil
   local fh, err = io.open(path, "r")
   if not fh then
      return nil, err
   end
   local data = fh:read("*a")
   fh:close()
   return data, nil
end

local function find_include(path: string, state: State, is_system: boolean): string | nil
   local try_paths: {string} = {}
   if not is_system then
      table.insert(try_paths, state.current_dir)
   end
   for _, p in ipairs(state.search_paths) do
      table.insert(try_paths, p)
   end
   local seen: {string:boolean} = {}
   for _, base in ipairs(try_paths) do
      if not seen[base] then
         seen[base] = true
         local candidate = base .. "/" .. path
         local data, _ = read_file(candidate)
         if data then
            return candidate
         end
      end
   end
   return nil
end

local function parse_include_target(tokens: {Token}, raw_source: string): string | nil, boolean
   local _ = raw_source
   if #tokens == 0 then
      return nil, false
   end
   local first = tokens[1]
   if first.kind == TK_STRING then
      local stripped = first.lexeme:gsub("^\"", ""):gsub("\"$", "")
      return stripped, false
   end
   if first.kind == TK_PUNCT and first.lexeme == "<" then
      local pieces: {string} = {}
      for _, t in ipairs(tokens) do
         if t.kind == TK_PUNCT and t.lexeme == ">" then
            break
         elseif t.kind == TK_PUNCT and t.lexeme ~= "<" then
            table.insert(pieces, t.lexeme)
         elseif t.kind == TK_IDENTIFIER or t.kind == TK_NUMBER then
            table.insert(pieces, t.lexeme)
         end
      end
      return table.concat(pieces), true
   end
   return nil, false
end

local function collect_line(tokens: {Token}, start_idx: integer): {Token}, integer
   local line: {Token} = {}
   local idx = start_idx
   local line_no = tokens[start_idx].span.line
   while idx <= #tokens do
      local t = tokens[idx]
      if #line > 0 and t.span.line > line_no then
         break
      end
      table.insert(line, t)
      idx = idx + 1
      if t.kind == TK_EOF then
         break
      end
   end
   return line, idx
end


local function preprocess_inner(source: string, file_id: integer, reporter: Reporter, config: PreprocessConfig, state: State, current_path?: string): PreprocessResult
   local _ = config
   local prev_dir = state.current_dir
   if current_path then
      state.current_dir = path_dir(current_path)
      state.file_paths[file_id] = current_path
   end
   local text = replace_trigraphs(source)
   text = normalize_newlines(text)
   reporter:track_file(file_id, current_path, text)
   text = splice_lines(text, reporter, file_id)
   reporter:track_file(file_id, current_path, text)

   local raw_tokens = Lexer.lex_all(text, file_id, reporter)
   local out_tokens: {Token} = {}
   local cond_stack: {ConditionalState} = {}

   local idx = 1
   while idx <= #raw_tokens do
      local t = raw_tokens[idx]
      local at_line_start = (idx == 1) or raw_tokens[idx].span.line > raw_tokens[idx - 1].span.line
      local skip_active = (#cond_stack > 0 and cond_stack[#cond_stack].skipping) or false
      if t.kind == TK_EOF then
         table.insert(out_tokens, t)
         break
      end

      if skip_active and not (at_line_start and t.kind == TK_PUNCT and t.lexeme == "#") then
         idx = idx + 1
      elseif at_line_start and t.kind == TK_PUNCT and t.lexeme == "#" then
         local line_tokens, next_idx = collect_line(raw_tokens, idx)
         idx = next_idx
         table.remove(line_tokens, 1) -- drop '#'
         local directive = line_tokens[1]
         if directive and (directive.kind == TK_IDENTIFIER or directive.kind == TK_KEYWORD) then
            local name = directive.lexeme
            local body = {}
            for i = 2, #line_tokens do
               table.insert(body, line_tokens[i])
            end
            local parent_skip = skip_active

            if name == "define" and not parent_skip then
               parse_define(body, state)
            elseif name == "undef" and not parent_skip then
               if body[1] and body[1].kind == TK_IDENTIFIER then
                  state.macros[body[1].lexeme] = nil
               end
            elseif name == "ifdef" or name == "ifndef" then
               local should_skip = false
               if #body > 0 and body[1].kind == TK_IDENTIFIER then
                  local present = state.macros[body[1].lexeme] ~= nil
                  should_skip = name == "ifdef" and not present or name == "ifndef" and present
               else
                  should_skip = true
               end
               local taken = not should_skip and not parent_skip
               local effective_skip = parent_skip or should_skip
               table.insert(cond_stack, { skipping = effective_skip, branch_taken = taken, in_else = false })
            elseif name == "if" then
               local cond = false
               if not parent_skip then
                  cond = parse_if_expr(body, state)
               end
               local effective_skip = parent_skip or not cond
               local taken = cond and not parent_skip
               table.insert(cond_stack, { skipping = effective_skip, branch_taken = taken, in_else = false })
            elseif name == "elif" then
               if #cond_stack == 0 then
                  reporter:report(Diagnostic.new("error", "#elif without #if", t.span, "PP100"))
               else
                  local top = cond_stack[#cond_stack]
                  if top.in_else then
                     reporter:report(Diagnostic.new("error", "#elif after #else", t.span, "PP101"))
                  else
                     local outer_skip = (#cond_stack > 1 and cond_stack[#cond_stack - 1].skipping) or false
                     if not top.branch_taken and not outer_skip then
                        local cond = parse_if_expr(body, state)
                        top.skipping = not cond
                        top.branch_taken = cond
                     else
                        top.skipping = true
                     end
                     cond_stack[#cond_stack] = top
                  end
               end
            elseif name == "else" then
               if #cond_stack == 0 then
                  reporter:report(Diagnostic.new("error", "#else without #if", t.span, "PP102"))
               else
                  local top = cond_stack[#cond_stack]
                  if top.in_else then
                     reporter:report(Diagnostic.new("error", "duplicate #else", t.span, "PP103"))
                  else
                     top.in_else = true
                     local outer_skip = (#cond_stack > 1 and cond_stack[#cond_stack - 1].skipping) or false
                     if top.branch_taken or outer_skip then
                        top.skipping = true
                     else
                        top.skipping = false
                        top.branch_taken = true
                     end
                     cond_stack[#cond_stack] = top
                  end
               end
            elseif name == "endif" then
               if #cond_stack == 0 then
                  reporter:report(Diagnostic.new("error", "#endif without #if", t.span, "PP104"))
               else
                  cond_stack[#cond_stack] = nil
               end
            elseif name == "include" and not parent_skip then
               local target, is_system = parse_include_target(body, text)
               if target then
                  local resolved = find_include(target, state, is_system)
                  if not resolved then
                     reporter:report(Diagnostic.new("error", "include not found: " .. target, t.span, "PP200"))
                  elseif state.pragma_once[resolved] then
                     -- skip repeated include due to pragma once
                  else
                     local data, err = read_file(resolved)
                     if not data then
                        reporter:report(Diagnostic.new("error", "failed to read include: " .. tostring(err), t.span, "PP201"))
                     else
                        local include_result = preprocess_inner(data, state.next_file_id, reporter, {
                           search_paths = state.search_paths,
                           defines = {},
                           undefs = {},
                           current_dir = state.current_dir,
                           source_path = resolved,
                        }, state, resolved)
                        state.next_file_id = state.next_file_id + 1
                        for _, itok in ipairs(include_result.tokens) do
                           if itok.kind ~= TK_EOF then
                              table.insert(out_tokens, itok)
                           end
                        end
                     end
                  end
               end
            elseif name == "pragma" then
               if not parent_skip and body[1] and body[1].kind == TK_IDENTIFIER and body[1].lexeme == "once" then
                  if body[2] and body[2].kind ~= TK_EOF then
                     -- extra tokens, warn
                  end
                  if current_path then
                     state.pragma_once[current_path] = true
                  end
               end
            elseif name == "line" and not parent_skip then
               if #body >= 1 and body[1].kind == TK_NUMBER then
                  local desired = tonumber(body[1].lexeme)
                  if desired then
                     local current_line = t.span.line
                     -- Per C99, the line number specified applies to the next line after the directive.
                     state.file_line_adjust[file_id] = math.floor(desired) - (current_line + 1)
                     if body[2] and body[2].kind == TK_STRING then
                        local fname = body[2].lexeme:gsub('^"', ""):gsub('"$', "")
                        state.file_name_override[file_id] = fname
                     end
                  end
               end
            elseif name == "error" then
               if not parent_skip then
                  local msg_parts: {string} = {}
                  for _, bt in ipairs(body) do
                     table.insert(msg_parts, bt.lexeme)
                  end
                  local msg = table.concat(msg_parts, " ")
                  reporter:report(Diagnostic.new("error", "#error " .. msg, t.span, "PP300"))
               end
            elseif name == "warning" then
               if not parent_skip then
                  local msg_parts: {string} = {}
                  for _, bt in ipairs(body) do
                     table.insert(msg_parts, bt.lexeme)
                  end
                  local msg = table.concat(msg_parts, " ")
                  reporter:report(Diagnostic.new("warning", "#warning " .. msg, t.span, "PP301"))
               end
            else
               -- other directives ignored for now
            end
         end
      else
         table.insert(out_tokens, t)
         idx = idx + 1
      end
   end

   local expanded = expand_macros(out_tokens, state)
   local final_tokens: {Token} = {}
   local has_eof = false
   for _, t in ipairs(expanded) do
      table.insert(final_tokens, t)
      if t.kind == TK_EOF then
         has_eof = true
      end
   end
   if not has_eof then
      table.insert(final_tokens, make_token(TK_EOF, "", Span.new(file_id, #text, #text, 1, 1)))
   end

   local final_text = text_from_tokens(final_tokens)
   state.current_dir = prev_dir

    -- Unclosed conditionals
   if #cond_stack > 0 then
      reporter:report(Diagnostic.new("error", "unterminated conditional directive", Span.new(file_id, #text, #text, 1, 1), "PP400"))
   end

   return { text = final_text, tokens = final_tokens, file_id = file_id }
end

local function preprocess(source: string, file_id: integer, reporter?: Reporter, config?: PreprocessConfig): PreprocessResult
   local rep = reporter or Reporter.new()
   local cfg = config or { search_paths = { "." }, defines = {}, undefs = {}, current_dir = ".", source_path = nil }
   local state = make_state(rep, cfg, file_id)
   return preprocess_inner(source, file_id, rep, cfg, state, cfg.source_path)
end

local function preprocess_file(path: string, file_id: integer, reporter?: Reporter, config?: PreprocessConfig): PreprocessResult
   local rep = reporter or Reporter.new()
   rep:track_file(file_id, path)
   local file, open_err = io.open(path, "r")
   if file is nil then
      local span = Span.new(file_id, 0, 0, 1, 1)
      rep:report(Diagnostic.new("error", "failed to read file: " .. open_err, span, "PP000"))
      return { text = "", tokens = {}, file_id = file_id }
   end
   local src = file:read("*a") or ""
   file:close()
   rep:track_file(file_id, path, src)
   local cfg = config or { search_paths = {}, defines = {}, undefs = {}, current_dir = nil, source_path = path }
   cfg.current_dir = cfg.current_dir or (cfg.source_path and path_dir(cfg.source_path)) or "."
   cfg.search_paths = cfg.search_paths or { cfg.current_dir }
   cfg.source_path = cfg.source_path or path
   return preprocess(src, file_id, rep, cfg)
end

return {
   PreprocessConfig = PreprocessConfig,
   PreprocessResult = PreprocessResult,
   preprocess = preprocess,
   preprocess_file = preprocess_file,
}
