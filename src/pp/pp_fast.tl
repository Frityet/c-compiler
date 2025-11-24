local ffi = require("ffi")
local LexerFast = require("lexer.lexer")
-- local Span = require("util.span")
local Reporter = require("diag.reporter")
-- local Diagnostic = require("diag.diagnostics")
local bit = require("bit")

-- local ffi_token_type = ffi.typeof("tl_token_fast")
-- local ffi_token_array_type = ffi.typeof("tl_token_fast[?]")
-- local ffi_token_ptr_type = ffi.typeof("tl_token_fast*")

-- local type TokenC = LexerFast.TokenC
-- local type TokenKind = LexerFast.TokenKind

-- local type TokenCArray = ffi.CData

local type TokenCPtr = ffi.Pointer<LexerFast.TokenC>
-- local type VoidPtr = ffi.Pointer<ffi.CData>

local record MacroC
   name: string
   params: {string} | nil
   is_variadic: boolean
   replacement: ffi.Array<LexerFast.TokenC>
   replacement_len: integer
   is_function: boolean
   built_in: string | nil
end

local record SourceManager
   sources: {integer:string}
   ptrs: {integer:ffi.Pointer<integer>} -- uint8_t*
end

local last_file_id = -1
local last_ptr: ffi.Pointer<integer> = nil

local function get_lexeme(mgr: SourceManager, tok: LexerFast.TokenC): string
   local ptr: ffi.Pointer<integer>
   if tok.file_id == last_file_id and last_ptr then
      ptr = last_ptr
   else
      ptr = mgr.ptrs[tok.file_id]
      last_file_id = tok.file_id
      last_ptr = ptr
   end
   if not ptr then return "" end
   return ffi.string(ptr + tok.start, tok.stop - tok.start)
end

ffi.cdef[[
    int memcmp(const void *s1, const void *s2, size_t n);

    typedef struct MacroEntry {
        const char* key;
        int key_len;
        int index; /* Index into Lua array (1-based) */
        struct MacroEntry* next;
    } MacroEntry;

    typedef struct {
        MacroEntry** buckets;
        int size;
        int count;
    } MacroTable;
]]

local record MacroEntry is ffi.CData where ffi.istype(self, "MacroEntry")
   key: ffi.CString
   key_len: integer
   index: integer
   next: ffi.Pointer<MacroEntry> | nil
end

local record MacroTable is ffi.CData where ffi.istype(self, "MacroTable")
   buckets: ffi.Array<ffi.Pointer<MacroEntry>> | nil
   size: integer
   count: integer
end

local function hash_bytes(ptr: ffi.Pointer<integer>, len: integer): integer
    local h = 5381
    local p: ffi.Pointer<integer> = ffi.cast("uint8_t*", ptr)
    local limit = len
    if limit > 16 then limit = 16 end
    for i = 0, limit - 1 do
        h = h * 33 + p[i]
    end
    return bit.bor(h, 0)
end

local function new_macro_table(size: integer, refs: {any}): MacroTable
    local t: MacroTable = ffi.new("MacroTable")
    t.size = size
    local buckets: ffi.Array<ffi.Pointer<MacroEntry>> = ffi.new("MacroEntry*[?]", size)
    t.buckets = buckets
    t.count = 0
    table.insert(refs, buckets)
    return t
end

local function macro_table_get(t: MacroTable, ptr: ffi.Pointer<integer>, len: integer): integer
    -- print("get", len)
    local h = hash_bytes(ptr, len)
    local idx = bit.band(h, t.size - 1)
    local bck = t.buckets
    if bck is nil then return 0 end
    local entry = bck[idx]
    while not entry is nil do
        if entry[0].key_len == len and (ffi.C.memcmp as function(ffi.CData, ffi.CData, integer): integer)(entry[0].key, ptr, len) == 0 then
            return entry[0].index
        end
        entry = entry[0].next
    end
    return 0
end

local function macro_table_put(t: MacroTable, key: string, index: integer, refs: {any}): MacroEntry
    local len = #key
    local h = hash_bytes(ffi.cast("uint8_t*", key), len)
    local idx = bit.band(h, t.size - 1)
    
    -- Check if exists
    local bck = t.buckets
    if bck is nil then return nil end
    local entry = bck[idx]
    while not entry is nil do
        if entry[0].key_len == len and (ffi.C.memcmp as function(ffi.CData, ffi.String, integer): integer)(entry[0].key, key, len) == 0 then
            entry[0].index = index
            return nil
        end
        entry = entry[0].next
    end
    
    -- Add new
    local new_entry: MacroEntry = ffi.new("MacroEntry")
    local key_copy: ffi.CString = ffi.new("char[?]", len + 1)
    ffi.copy(key_copy, key, len)
    new_entry.key = key_copy
    new_entry.key_len = len
    new_entry.index = index
    new_entry.next = bck[idx]
    
    -- Anchor objects
    table.insert(refs, new_entry)
    table.insert(refs, key_copy)
    
    -- We need to assign the pointer to the bucket.
    bck[idx] = ffi.cast("MacroEntry*", new_entry)
    t.count = t.count + 1
    return new_entry
end

local record PPState
   macros: {MacroC}
   macro_table: MacroTable
   macro_refs: {any}
   mgr: SourceManager
   reporter: Reporter
   -- ... other state
end

local record TokenSource
   next: function(): LexerFast.TokenC
   peek: function(): LexerFast.TokenC
   is_file: boolean
end

local function read_file(path: string): string | nil
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function resolve_include(path: string, _: PPState): string | nil
   -- Simple resolution for now
   local f = io.open(path, "r")
   if f then
      f:close()
      return path
   end
   return nil
end

local function replace_trigraphs(src: string): string
   local trigraphs: {string:string} = {
      ["??="] = "#", ["??/"] = "\\", ["??'"] = "^", ["??("] = "[", ["??)"] = "]",
      ["??!"] = "|", ["??<"] = "{", ["??>"] = "}", ["??-"] = "~",
   }
   return (src:gsub("%?%?.", function(seq: string): string
      return trigraphs[seq] or seq
   end))
end

local function normalize_newlines(src: string): string
   src = src:gsub("\r\n", "\n")
   src = src:gsub("\r", "\n")
   return src
end

local function splice_lines(src: string): string
   return (src:gsub("\\\n", ""))
end

local function new_lexer_source(src: string, file_id: integer, mgr: SourceManager): TokenSource
   src = replace_trigraphs(src)
   src = normalize_newlines(src)
   src = splice_lines(src)
   
   mgr.sources[file_id] = src
   local c_str = ffi.cast("const uint8_t*", src)
   mgr.ptrs[file_id] = ffi.cast("uint8_t*", c_str)
   
   local lex = LexerFast.new_lexer(src, file_id)
   local buffer_arr: ffi.Array<LexerFast.TokenC> = ffi.new("tl_token_fast[1]")
   local has_buffer = false
   
   local function peek(): LexerFast.TokenC
      if has_buffer then
         return buffer_arr[0]
      end
      local t = LexerFast.next_token(lex)
      ffi.copy(buffer_arr, t, ffi.sizeof("tl_token_fast"))
      has_buffer = true
      return buffer_arr[0]
   end

   local function next_token(): LexerFast.TokenC
      if has_buffer then
         has_buffer = false
         return buffer_arr[0]
      end
      return LexerFast.next_token(lex)
   end
   
   return {
      next = next_token,
      peek = peek,
      is_file = true
   }
end


local record TokenVector
   data: ffi.Array<LexerFast.TokenC> -- tl_token_fast[]
   size: integer
   capacity: integer
end

local function new_token_vector(capacity?: integer): TokenVector
   capacity = capacity or 16
   local arr: ffi.Array<LexerFast.TokenC> = ffi.new("tl_token_fast[?]", capacity)
   return {
      data = arr,
      size = 0,
      capacity = capacity
   }
end

local function vec_push(vec: TokenVector, tok: LexerFast.TokenC)
   if vec.size >= vec.capacity then
      local new_cap = vec.capacity * 2
      local new_arr: ffi.Array<LexerFast.TokenC> = ffi.new("tl_token_fast[?]", new_cap)
      ffi.copy(new_arr, vec.data, vec.size * ffi.sizeof("tl_token_fast"))
      vec.data = new_arr
      vec.capacity = new_cap
   end
   -- Copy token content
   ffi.copy(vec.data + vec.size, tok, ffi.sizeof("tl_token_fast"))
   vec.size = vec.size + 1
end

local function new_macro_source(macro: MacroC): TokenSource
   local idx = 0
   local len = macro.replacement_len
   local rep = macro.replacement
   
   local function next_token(): LexerFast.TokenC
      if idx >= len then
         local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
         eof.kind = LexerFast.K_EOF
         return eof
      end
      local t = rep[idx]
      idx = idx + 1
      return t
   end
   
   local function peek(): LexerFast.TokenC
      if idx >= len then
         local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
         eof.kind = LexerFast.K_EOF
         return eof
      end
      return rep[idx]
   end
   
   return {
      next = next_token,
      peek = peek,
      is_file = false
   }
end



local function parse_define(tokens: TokenVector, state: PPState)
   if tokens.size == 0 then return end
   
   local ptr = tokens.data
   local name_tok = ptr[0]
   if name_tok.kind ~= LexerFast.K_IDENTIFIER then return end
   
   local name = get_lexeme(state.mgr, name_tok)
   
   local is_function = false
   local params: {string} | nil = nil
   local is_variadic = false
   local replacement_start = 1
   
   if tokens.size > 1 then
      local next_tok = ptr[1]
      -- Check adjacency: start of next must equal stop of name
      if next_tok.kind == LexerFast.K_PUNCT and get_lexeme(state.mgr, next_tok) == "(" and
         next_tok.start == name_tok.stop then
         is_function = true
         params = {}
         replacement_start = 2
         
         local i = 2
         while i < tokens.size do
            local t = ptr[i]
            if t.kind == LexerFast.K_PUNCT and get_lexeme(state.mgr, t) == ")" then
               replacement_start = i + 1
               break
            elseif t.kind == LexerFast.K_PUNCT and get_lexeme(state.mgr, t) == "," then
               i = i + 1
            elseif t.kind == LexerFast.K_PUNCT and get_lexeme(state.mgr, t) == "..." then
               is_variadic = true
               params[#params + 1] = "__VA_ARGS__"
               i = i + 1
            elseif t.kind == LexerFast.K_IDENTIFIER then
               params[#params + 1] = get_lexeme(state.mgr, t)
               i = i + 1
            else
               i = i + 1
            end
         end
      end
   end
   
   -- Create replacement array
   local rep_len = tokens.size - replacement_start
   local rep_arr: ffi.Array<LexerFast.TokenC> = ffi.new("tl_token_fast[?]", rep_len > 0 and rep_len or 1)
   if rep_len > 0 then
      ffi.copy(rep_arr, ptr + replacement_start, rep_len * ffi.sizeof("tl_token_fast"))
   end
   
   local macro: MacroC = {
      name = name,
      params = params,
      is_variadic = is_variadic,
      replacement = rep_arr,
      replacement_len = rep_len,
      is_function = is_function,
      built_in = nil
   }
   
   table.insert(state.macros, macro)
   macro_table_put(state.macro_table, name, #state.macros, state.macro_refs)
end

local function parse_macro_args(source: TokenSource, mgr: SourceManager): {TokenVector}
   local args: {TokenVector} = {}
   local depth = 0
   local current = new_token_vector()
   
   while true do
      local t = source.peek()
      if t.kind == LexerFast.K_EOF then
         break
      end
      
      if t.kind == LexerFast.K_PUNCT and get_lexeme(mgr, t) == "(" then
         depth = depth + 1
         vec_push(current, t)
         source.next()
      elseif t.kind == LexerFast.K_PUNCT and get_lexeme(mgr, t) == ")" then
         if depth == 0 then
            source.next() -- consume ')'
            args[#args + 1] = current
            return args
         else
            depth = depth - 1
            vec_push(current, t)
            source.next()
         end
      elseif t.kind == LexerFast.K_PUNCT and get_lexeme(mgr, t) == "," and depth == 0 then
         source.next() -- consume ','
         args[#args + 1] = current
         current = new_token_vector()
      else
         vec_push(current, t)
         source.next()
      end
   end
   return args
end

local function substitute_macro(macro: MacroC, args: {TokenVector}, state: PPState): TokenVector
   local out = new_token_vector()
   local rep = macro.replacement
   local len = macro.replacement_len
   
   local arg_map: {string: TokenVector} = {}
   local params = macro.params
   if not params is nil then
      for i, param in ipairs(params) do
         if args[i] then
            arg_map[param] = args[i]
         end
      end
   end
   
   if macro.is_variadic then
      local va_args = new_token_vector()
      local start_idx = macro.params and #macro.params + 1 or 1
      for j = start_idx, #args do
          local arg_v = args[j]
          if j > start_idx then
              -- TODO: Insert comma
          end
          local arg_ptr = arg_v.data
          for k = 0, arg_v.size - 1 do
              vec_push(va_args, arg_ptr[k])
          end
      end
      arg_map["__VA_ARGS__"] = va_args
   end

   local i = 0
   while i < len do
      local tok = rep[i]
      if tok.kind == LexerFast.K_IDENTIFIER then
         local lexeme = get_lexeme(state.mgr, tok)
         if arg_map[lexeme] then
             local arg_vec = arg_map[lexeme]
             local arg_ptr = arg_vec.data
             for k = 0, arg_vec.size - 1 do
                 vec_push(out, arg_ptr[k])
             end
         else
             vec_push(out, tok)
         end
      else
         vec_push(out, tok)
      end
      i = i + 1
   end
   
   return out
end

local function parse_include_target(tokens: TokenVector, mgr: SourceManager): string | nil, boolean
   if tokens.size == 0 then return nil, false end
   local ptr = tokens.data
   local first = ptr[0]
   
   if first.kind == LexerFast.K_STRING then
      local s = get_lexeme(mgr, first)
      return s:sub(2, -2), false -- strip quotes
   elseif first.kind == LexerFast.K_PUNCT and get_lexeme(mgr, first) == "<" then
      local pieces: {string} = {}
      for i = 1, tokens.size - 1 do
         local t = ptr[i]
         local lx = get_lexeme(mgr, t)
         if t.kind == LexerFast.K_PUNCT and lx == ">" then
            break
         end
         pieces[#pieces + 1] = lx
      end
      return table.concat(pieces), true
   end
   return nil, false
end

local function handle_directive(source: TokenSource, state: PPState, directive_line: integer, stack: {TokenSource})
   local line_tokens = new_token_vector()
   
   while true do
      local t = source.peek()
      if t.kind == LexerFast.K_EOF or t.line > directive_line then
         break
      end
      vec_push(line_tokens, t)
      source.next()
   end
   
   if line_tokens.size == 0 then return end
   
   local ptr = line_tokens.data
   local dir_tok = ptr[0]
   
   if dir_tok.kind == LexerFast.K_IDENTIFIER then
      local name = get_lexeme(state.mgr, dir_tok)
      
      if name == "define" then
         local def_tokens = new_token_vector()
         for i = 1, line_tokens.size - 1 do
             vec_push(def_tokens, ptr[i])
         end
         parse_define(def_tokens, state)
      elseif name == "include" then
         local inc_tokens = new_token_vector()
         for i = 1, line_tokens.size - 1 do
             vec_push(inc_tokens, ptr[i])
         end
         local path, _ = parse_include_target(inc_tokens, state.mgr)
         if path then
             local resolved = resolve_include(path, state)
             if resolved then
                 local new_src = read_file(resolved)
                 if new_src then
                     local file_id = 0 -- TODO: Generate file ID
                     -- We need a way to generate file IDs. state.mgr.sources is a map.
                     -- Let's assume we can just use a counter or #sources + 1 if it was an array.
                     -- But sources is {integer:string}.
                     -- Let's find a max id or keep track of it.
                     -- For now, let's just use a random large number or fix SourceManager.
                     file_id = 1000 + math.random(1000) -- Hack for now
                     
                     local inc_source = new_lexer_source(new_src, file_id, state.mgr)
                     stack[#stack + 1] = inc_source
                 end
             end
         end
      end
   end
end

local function preprocess(src: string, file_id: integer, reporter: Reporter): TokenSource
   local mgr: SourceManager = {
      sources = {},
      ptrs = {}
   }
   local refs: {any} = {}
   local state: PPState = {
      macros = {},
      macro_table = new_macro_table(4096, refs),
      macro_refs = refs,
      mgr = mgr,
      reporter = reporter
   }
   
   local initial_source = new_lexer_source(src, file_id, mgr)
   local stack: {TokenSource} = { initial_source }
   
   local function next_token(): LexerFast.TokenC
      while #stack > 0 do
         local top = stack[#stack]
         local tok = top.peek() -- Peek first to check for directive
         
         if tok.kind == LexerFast.K_EOF then
            top.next() -- Consume EOF
            table.remove(stack)
         elseif top.is_file and tok.kind == LexerFast.K_PUNCT and get_lexeme(mgr, tok) == "#" then
             top.next() -- Consume '#'
             handle_directive(top, state, tok.line, stack)
         elseif tok.kind == LexerFast.K_IDENTIFIER then
             top.next() -- Consume identifier
             
             local ptr: ffi.Pointer<integer>
             if tok.file_id == last_file_id and last_ptr then
                ptr = last_ptr
             else
                ptr = mgr.ptrs[tok.file_id]
                last_file_id = tok.file_id
                last_ptr = ptr
             end
             
             local macro_idx = 0
             if ptr then
                 macro_idx = macro_table_get(state.macro_table, ptr + tok.start, tok.stop - tok.start)
             end
             
             local macro: MacroC = nil
             if macro_idx > 0 then
                 macro = state.macros[macro_idx]
             end

             if macro then
                -- Check if it's a function-like macro and if it has arguments
                if macro.is_function then
                   local next_tok = top.peek()
                   if next_tok.kind == LexerFast.K_PUNCT and get_lexeme(mgr, next_tok) == "(" then
                      local args = parse_macro_args(top, mgr)
                      local expanded = substitute_macro(macro, args, state)
                      -- Create a source from the expanded vector
                      
                      local idx = 0
                      local len = expanded.size
                      local exp_ptr = expanded.data
                      
                      local function vec_next(): LexerFast.TokenC
                          if idx >= len then
                              local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
                              eof.kind = LexerFast.K_EOF
                              return eof
                          end
                          local t = exp_ptr[idx]
                          idx = idx + 1
                          return t
                      end
                      
                      local function vec_peek(): LexerFast.TokenC
                          if idx >= len then
                              local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
                              eof.kind = LexerFast.K_EOF
                              return eof
                          end
                          return exp_ptr[idx]
                      end
                      
                      stack[#stack + 1] = { next = vec_next, peek = vec_peek, is_file = false }
                   else
                      return tok
                   end
                else
                   local ms = new_macro_source(macro)
                   stack[#stack + 1] = ms
                end
             else
                return tok
             end
         else
             top.next() -- Consume
             return tok
         end
      end
      
      local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
      eof.kind = LexerFast.K_EOF
      return eof
   end
   
   return {
      next = next_token,
      peek = function(): LexerFast.TokenC
         if #stack == 0 then
            local eof: LexerFast.TokenC = ffi.new("tl_token_fast")
            eof.kind = LexerFast.K_EOF
            return eof
         end
         return stack[#stack].peek()
      end,
      is_file = false
   }
end


return {
   new_lexer_source = new_lexer_source,
   get_lexeme = get_lexeme,
   preprocess = preprocess,
   parse_define = parse_define,
   parse_macro_args = parse_macro_args,
   substitute_macro = substitute_macro,
}
