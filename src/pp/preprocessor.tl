local ffi = require("ffi")
local lexer = require("lexer.lexer")
local C = ffi.C
local Reporter = require("diag.reporter")
local Diagnostic = require("diag.diagnostics")
local bit = require("bit")

-- local ffi_token_type = ffi.typeof("tl_token_fast")
-- local ffi_token_array_type = ffi.typeof("tl_token_fast[?]")
-- local ffi_token_ptr_type = ffi.typeof("tl_token_fast*")

-- local type TokenPtr = ffi.Pointer<lexer.Token>

local record MacroC
   name: string
   params: {string} | nil
   is_variadic: boolean
   replacement: ffi.Array<lexer.Token>
   replacement_len: integer
   is_function: boolean
   built_in: string | nil
end

local record SourceManager
   sources: {integer:string}
   ptrs: {integer:ffi.CString}
   buffers: {integer:ffi.CData}
   paths: {integer:string}
   infos: {integer: SourceInfo}
   next_id: integer
end

local record SourceInfo
   path: string
   line_delta: integer
end

local record PPOptions
   search_paths: {string} | nil
   system_paths: {string} | nil
   defines: {string:string} | nil
   undefs: {string:boolean} | nil
   current_dir: string | nil
   source_path: string | nil
end

local type BytePtr = ffi.CString
local type StringView = lexer.StringView

local EMPTY_STR_PTR<const>: BytePtr = ffi.cast("const char*", "")
local EMPTY_VIEW<const>: StringView = ffi.new("struct tl_string_view", EMPTY_STR_PTR, 0)

local function get_lexeme(mgr: SourceManager, tok: lexer.Token): StringView
   local ptr: BytePtr | nil = mgr.ptrs[tok.file_id]
   if ptr == nil then
      return EMPTY_VIEW
   end
   return tok:lexeme(ptr)
end

local function lexeme_to_string(view: StringView): string
   return ffi.string(view.ptr, view.len)
end

local function lexeme_eq(mgr: SourceManager, tok: lexer.Token, lit: string): boolean
   local view = get_lexeme(mgr, tok)
   if view.len ~= #lit then
       return false
   end
   return (C.memcmp as function(ffi.CData, ffi.String, integer): integer)(view.ptr, lit, view.len) == 0
end

local function view_eq(view: StringView, lit: string): boolean
   if view.len ~= #lit then
      return false
   end
   return (C.memcmp as function(ffi.CData, ffi.String, integer): integer)(view.ptr, lit, view.len) == 0
end

local function path_dir(path: string): string
   local dir = path:match("^(.*)/[^/]+$") or "."
   if dir == "" then
      return "."
   end
   return dir
end

local function ensure_source_info(mgr: SourceManager, file_id: integer): SourceInfo
   local info = mgr.infos[file_id]
   if info is nil then
      info = { path = mgr.paths[file_id] or "", line_delta = 0 }
      mgr.infos[file_id] = info
   end
   return info
end

local function next_file_id(mgr: SourceManager): integer
   local id = mgr.next_id
   mgr.next_id = mgr.next_id + 1
   return id
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

local function macro_table_delete(t: MacroTable, key: string)
    local len = #key
    local h = hash_bytes(ffi.cast("uint8_t*", key), len)
    local idx = bit.band(h, t.size - 1)
    local bck = t.buckets
    if bck is nil then return end
    local entry = bck[idx]
    local prev: ffi.Pointer<MacroEntry> | nil = nil
    while not entry is nil do
        if entry[0].key_len == len and (ffi.C.memcmp as function(ffi.CData, ffi.String, integer): integer)(entry[0].key, key, len) == 0 then
            if prev is nil then
                bck[idx] = entry[0].next
            else
                prev[0].next = entry[0].next
            end
            return
        end
        prev = entry
        entry = entry[0].next
    end
end

local TRIGRAPH_MAP<const>: {string:string} = {
   ["??="] = "#", ["??/"] = "\\", ["??'"] = "^", ["??("] = "[", ["??)"] = "]",
   ["??!"] = "|", ["??<"] = "{", ["??>"] = "}", ["??-"] = "~",
}

local record CondFrame
   parent_active: boolean
   taken: boolean
   else_seen: boolean
end

local record PPState
   macros: {MacroC}
   macro_table: MacroTable
   macro_refs: {any}
   macro_map: {string: integer}
   mgr: SourceManager
   reporter: Reporter
   once_paths: {string:boolean}
   cond_stack: {CondFrame}
   active: boolean
   expanding: {string:boolean}
   opts: PPOptions
   date_literal: string
   time_literal: string
end

local function macro_index(state: PPState, tok: lexer.Token): integer
   local mgr = state.mgr
   local ptr: BytePtr | nil = mgr.ptrs[tok.file_id]
   if ptr is nil then return 0 end
   local base: ffi.Pointer<integer> = ffi.cast("const uint8_t*", ptr)
   local idx = macro_table_get(state.macro_table, base + tok.start, tok.stop - tok.start)
   if idx == 0 then
      local name_view = get_lexeme(mgr, tok)
      local map_idx = state.macro_map[lexeme_to_string(name_view)]
      if not map_idx is nil then
         return map_idx
      end
   end
   return idx
end

local record TokenSource
   next: function(): lexer.Token
   peek: function(): lexer.Token
   is_file: boolean
   lexer: lexer.LexerState | nil
   mgr: SourceManager | nil
   macro_name: string | nil
   vec: TokenVector | nil
end

local TOKEN_SIZE<const> = ffi.sizeof("tl_token_fast")
local ffi_copy<const> = ffi.copy

local function register_source(mgr: SourceManager, file_id: integer, src: string, path: string | nil)
   mgr.sources[file_id] = src
   local buf: ffi.CData = ffi.new("uint8_t[?]", #src + 1, src)
   mgr.buffers[file_id] = buf
   mgr.ptrs[file_id] = ffi.cast("const char*", buf)
   mgr.paths[file_id] = path or mgr.paths[file_id] or ""
   if mgr.infos[file_id] == nil then
      mgr.infos[file_id] = { path = mgr.paths[file_id] or "", line_delta = 0 }
   end
end

local function make_synthetic_token(mgr: SourceManager, lexeme: string, kind: integer): lexer.Token
   local fid = next_file_id(mgr)
   register_source(mgr, fid, lexeme, "<macro>")
   local tok: lexer.Token = ffi.new("tl_token_fast")
   tok.start = 0
   tok.stop = #lexeme
   tok.line = 1
   tok.col = 1
   tok.file_id = fid
   tok.kind = kind
   tok.flags = 0
   return tok
end

local function lex_single_token(mgr: SourceManager, text: string): lexer.Token
   local fid = next_file_id(mgr)
   register_source(mgr, fid, text, "<macro>")
   local lex = lexer.new_lexer(text, fid)
   local tok = lexer.next_token(lex)
   return tok
end

local function paste_tokens(left: lexer.Token, right: lexer.Token, mgr: SourceManager): lexer.Token
   local l = lexeme_to_string(get_lexeme(mgr, left))
   local r = lexeme_to_string(get_lexeme(mgr, right))
   return lex_single_token(mgr, l .. r)
end

local function define_object_macro(state: PPState, name: string, tokens: {lexer.Token}, built_in?: string)
   local len = #tokens
   local arr: ffi.Array<lexer.Token> = ffi.new("tl_token_fast[?]", len > 0 and len or 1)
   for i, t in ipairs(tokens) do
      ffi_copy(arr + (i - 1), t, TOKEN_SIZE)
   end
   local macro: MacroC = {
      name = name,
      params = nil,
      is_variadic = false,
      replacement = arr,
      replacement_len = len,
      is_function = false,
      built_in = built_in or nil,
   }
   table.insert(state.macros, macro)
   macro_table_put(state.macro_table, name, #state.macros, state.macro_refs)
   state.macro_map[name] = #state.macros
end

local function is_macro_defined(state: PPState, name: string): boolean
   return state.macro_map[name] ~= nil
end

local function remove_macro(state: PPState, name: string)
   macro_table_delete(state.macro_table, name)
   state.macro_map[name] = nil
end

local function install_builtins(state: PPState)
   define_object_macro(state, "__STDC__", { make_synthetic_token(state.mgr, "1", lexer.K_NUMBER) })
   define_object_macro(state, "__STDC_VERSION__", { make_synthetic_token(state.mgr, "199901L", lexer.K_NUMBER) })
   define_object_macro(state, "__FILE__", {}, "file")
   define_object_macro(state, "__LINE__", {}, "line")
   define_object_macro(state, "__DATE__", {}, "date")
   define_object_macro(state, "__TIME__", {}, "time")
end
local function read_file(path: string): string | nil
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function resolve_include(path: string, is_angle: boolean, state: PPState, current_path: string): string | nil
   local candidates: {string} = {}
   local search_paths: {string}
   if state.opts.search_paths then
      search_paths = state.opts.search_paths
   else
      search_paths = {}
   end
   local system_paths: {string}
   if state.opts.system_paths then
      system_paths = state.opts.system_paths
   else
      system_paths = {}
   end
   if not is_angle then
      candidates[#candidates + 1] = current_path ~= "" and (path_dir(current_path) .. "/" .. path) or path
   end
   for _, p in ipairs(search_paths) do
      candidates[#candidates + 1] = p .. "/" .. path
   end
   for _, p in ipairs(system_paths) do
      candidates[#candidates + 1] = p .. "/" .. path
   end
   for _, cand in ipairs(candidates) do
      local f = io.open(cand, "r")
      if f then
         f:close()
         return cand
      end
   end
   return nil
end

local function replace_trigraphs(src: string): string
   if not src:find("??", 1, true) then
      return src
   end
   return (src:gsub("%?%?.", function(seq: string): string
      return TRIGRAPH_MAP[seq] or seq
   end))
end

local function normalize_newlines(src: string): string
   if not src:find("\r", 1, true) then
      return src
   end
   local s = src:gsub("\r\n", "\n")
   local normalized = s:gsub("\r", "\n")
   return normalized
end

local function splice_lines(src: string): string
   if not src:find("\\\n", 1, true) then
      return src
   end
   return (src:gsub("\\\n", ""))
end

local function new_lexer_source(src: string, file_id: integer, mgr: SourceManager, path?: string): TokenSource
   src = replace_trigraphs(src)
   src = normalize_newlines(src)
   src = splice_lines(src)
   register_source(mgr, file_id, src, path)
   
   local lex = lexer.new_lexer(src, file_id)
   -- local buffer_arr: ffi.Array<lexer.Token> = ffi.new("tl_token_fast[1]")
   local buffer: lexer.Token = ffi.new("tl_token_fast")
   local has_buffer = false
   
   local function peek(): lexer.Token
      if has_buffer then
         return buffer
      end
      local t = lexer.next_token(lex)

      buffer.start = t.start
      buffer.stop = t.stop
      buffer.line = t.line
      buffer.col = t.col
      buffer.file_id = t.file_id
      buffer.kind = t.kind
      buffer.flags = t.flags

      has_buffer = true
      return buffer
   end

   local function next_token(): lexer.Token
      if has_buffer then
         has_buffer = false
         return buffer
      end
      return lexer.next_token(lex)
   end
   
   return {
      next = next_token,
      peek = peek,
      is_file = true,
      lexer = lex,
      mgr = mgr,
      macro_name = nil,
      vec = nil,
   }
end


local record TokenVector
   data: ffi.Array<lexer.Token> -- tl_token_fast[]
   size: integer
   capacity: integer
end

local vec_pool: {TokenVector} = {}

local function new_token_vector(capacity?: integer): TokenVector
   local cap = capacity or 16
   if capacity is nil then
      local pooled = vec_pool[#vec_pool]
      if pooled and pooled.capacity >= cap then
         vec_pool[#vec_pool] = nil
         pooled.size = 0
         return pooled
      end
   end
   local arr: ffi.Array<lexer.Token> = ffi.new("tl_token_fast[?]", cap)
   return { data = arr, size = 0, capacity = cap }
end

local function recycle_vector(vec: TokenVector)
   vec.size = 0
   vec_pool[#vec_pool + 1] = vec
end

local function vec_push(vec: TokenVector, tok: lexer.Token)
   if vec.size >= vec.capacity then
      local new_cap = vec.capacity * 2
      local new_arr: ffi.Array<lexer.Token> = ffi.new("tl_token_fast[?]", new_cap)
      ffi_copy(new_arr, vec.data, vec.size * ffi.sizeof("tl_token_fast"))
      vec.data = new_arr
      vec.capacity = new_cap
   end
   -- Copy token content
   ffi_copy(vec.data + vec.size, tok, ffi.sizeof("tl_token_fast"))
   vec.size = vec.size + 1
end

local function stringify_arg(arg_vec: TokenVector, mgr: SourceManager): lexer.Token
   local parts: {string} = {}
   local ptr = arg_vec.data
   for i = 0, arg_vec.size - 1 do
      parts[#parts + 1] = lexeme_to_string(get_lexeme(mgr, ptr[i]))
   end
   local joined = table.concat(parts, " ")
   joined = joined:gsub("\\", "\\\\")
   joined = joined:gsub("\"", "\\\"")
   local lexeme = "\"" .. joined .. "\""
   return make_synthetic_token(mgr, lexeme, lexer.K_STRING)
end

local function new_vector_source(vec: TokenVector, macro_name: string | nil): TokenSource
   local idx = 0
   local len = vec.size
   local ptr = vec.data
   local function next_token(): lexer.Token
      if idx >= len then
         local eof: lexer.Token = ffi.new("tl_token_fast")
         eof.kind = lexer.K_EOF
         return eof
      end
      local t = ptr[idx]
      idx = idx + 1
      return t
   end
   local function peek(): lexer.Token
      if idx >= len then
         local eof: lexer.Token = ffi.new("tl_token_fast")
         eof.kind = lexer.K_EOF
         return eof
      end
      return ptr[idx]
   end
   return {
      next = next_token,
      peek = peek,
      is_file = false,
      lexer = nil,
      mgr = nil,
      macro_name = macro_name,
      vec = vec, -- keep vector alive for the lifetime of this source
   }
end



local function parse_define(tokens: TokenVector, state: PPState)
   if tokens.size == 0 then return end
   
   local ptr = tokens.data
   local name_tok = ptr[0]
   if name_tok.kind ~= lexer.K_IDENTIFIER then return end
   
   local name = lexeme_to_string(get_lexeme(state.mgr, name_tok))
   
   local is_function = false
   local params: {string} | nil = nil
   local is_variadic = false
   local replacement_start = 1
   
   if tokens.size > 1 then
      local next_tok = ptr[1]
      -- Check adjacency: start of next must equal stop of name
      if next_tok.kind == lexer.K_PUNCT and lexeme_eq(state.mgr, next_tok, "(") and
         next_tok.start == name_tok.stop then
         is_function = true
         params = {}
         replacement_start = 2
         
         local i = 2
         while i < tokens.size do
            local t = ptr[i]
            if t.kind == lexer.K_PUNCT and lexeme_eq(state.mgr, t, ")") then
               replacement_start = i + 1
               break
            elseif t.kind == lexer.K_PUNCT and lexeme_eq(state.mgr, t, ",") then
               i = i + 1
            elseif t.kind == lexer.K_PUNCT and lexeme_eq(state.mgr, t, "...") then
               is_variadic = true
               params[#params + 1] = "__VA_ARGS__"
               i = i + 1
            elseif t.kind == lexer.K_IDENTIFIER then
               params[#params + 1] = lexeme_to_string(get_lexeme(state.mgr, t))
               i = i + 1
            else
               i = i + 1
            end
         end
      end
   end
   
   -- Create replacement array
   local rep_len = tokens.size - replacement_start
   local rep_arr: ffi.Array<lexer.Token> = ffi.new("tl_token_fast[?]", rep_len > 0 and rep_len or 1)
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
   state.macro_map[name] = #state.macros
end

   local function parse_macro_args(source: TokenSource, mgr: SourceManager): {TokenVector}
   local args: {TokenVector} = {}
   local depth = 0
   local current = new_token_vector()

   local first = source.peek()
   if first.kind == lexer.K_PUNCT and lexeme_eq(mgr, first, "(") then
      source.next()
      depth = 1
   end

   while true do
      local t = source.peek()
      if t.kind == lexer.K_EOF then
         break
      end

      if t.kind == lexer.K_PUNCT then
         if lexeme_eq(mgr, t, "(") then
            depth = depth + 1
            vec_push(current, t)
            source.next()
         elseif lexeme_eq(mgr, t, ")") then
            depth = depth - 1
            if depth == 0 then
               source.next()
               args[#args + 1] = current
               break
            else
               vec_push(current, t)
               source.next()
            end
         elseif depth == 1 and lexeme_eq(mgr, t, ",") then
            source.next()
            args[#args + 1] = current
            current = new_token_vector()
         else
            vec_push(current, t)
            source.next()
         end
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
   local mgr = state.mgr
   
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
      local start_idx = macro.params and #macro.params or 1
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
      if macro.is_function and lexeme_eq(mgr, tok, "#") and i + 1 < len then
         local nxt = rep[i + 1]
         if nxt.kind == lexer.K_IDENTIFIER then
            local name = lexeme_to_string(get_lexeme(mgr, nxt))
            local arg_vec = arg_map[name]
            if arg_vec then
               vec_push(out, stringify_arg(arg_vec, mgr))
               i = i + 2
               goto continue
            end
         end
      elseif lexeme_eq(mgr, tok, "##") then
         local next_idx = i + 1
         if next_idx < len and out.size > 0 then
            local right_tok = rep[next_idx]
            local right_view = get_lexeme(mgr, right_tok)
            local right_name = right_tok.kind == lexer.K_IDENTIFIER and lexeme_to_string(right_view) or nil
            local right_tokens = (right_name ~= nil) and arg_map[right_name] or nil
            local right_token: lexer.Token
            local remaining: TokenVector | nil = nil
            if not right_tokens is nil then
               right_token = right_tokens.data[0]
               remaining = right_tokens
            else
               right_token = right_tok
            end
            local left_tok = out.data[out.size - 1]
            out.size = out.size - 1
            vec_push(out, paste_tokens(left_tok, right_token, mgr))
            if not remaining is nil then
               for k = 1, remaining.size - 1 do
                  vec_push(out, remaining.data[k])
               end
            end
            i = i + 2
            goto continue
         end
      end

      if tok.kind == lexer.K_IDENTIFIER then
         local name = lexeme_to_string(get_lexeme(mgr, tok))
         local arg_vec = arg_map[name]
         if arg_vec then
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
      ::continue::
   end

   return out
end

local function recycle_args(args: {TokenVector})
   for i = 1, #args do
      recycle_vector(args[i])
   end
end

local function expand_builtin(macro: MacroC, tok: lexer.Token, state: PPState): TokenVector
   local out = new_token_vector()
   local mgr = state.mgr
   local info = ensure_source_info(mgr, tok.file_id)
   if macro.built_in == "line" then
      local ln = tok.line + info.line_delta
      vec_push(out, make_synthetic_token(mgr, tostring(ln), lexer.K_NUMBER))
   elseif macro.built_in == "file" then
      local p = info.path ~= "" and info.path or (mgr.paths[tok.file_id] or "")
      local escaped = p:gsub("\\", "\\\\"):gsub("\"", "\\\"")
      vec_push(out, make_synthetic_token(mgr, "\"" .. escaped .. "\"", lexer.K_STRING))
   elseif macro.built_in == "date" then
      vec_push(out, make_synthetic_token(mgr, "\"" .. state.date_literal .. "\"", lexer.K_STRING))
   elseif macro.built_in == "time" then
      vec_push(out, make_synthetic_token(mgr, "\"" .. state.time_literal .. "\"", lexer.K_STRING))
   end
   return out
end

local function parse_int_literal(text: string): integer
   local core = text:gsub("[uUlLfF]+$", "")
   if core:match("^0[xX]") then
      return (tonumber(core, 16) or 0) as integer
   end
   if core:match("^0[0-7]+") then
      local value: integer = 0
      for c in core:gmatch(".") do
         if c == "0" then
            value = value * 8
         else
            local digit = tonumber(c)
            if digit then
               value = (value * 8 + digit) as integer
            end
         end
      end
      return value
   end
   return (tonumber(core) or 0) as integer
end

local function parse_char_literal(text: string): integer
   local inner = text:match("^'(.*)'$")
   if inner is nil then
      return 0
   end
   if inner:sub(1, 1) == "\\" then
      local esc = inner:sub(2, 2)
      if esc == "n" then return 10 end
      if esc == "t" then return 9 end
      if esc == "r" then return 13 end
      if esc == "\\" then return 92 end
      if esc == "'" then return 39 end
      return tonumber(inner:sub(3), 8) or 0
   end
   return string.byte(inner) or 0
end

local function eval_defined(name: string, state: PPState): integer
   return is_macro_defined(state, name) and 1 or 0
end

local binary_prec: {string: integer} = {
   ["||"] = 1,
   ["&&"] = 2,
   ["|"] = 3,
   ["^"] = 4,
   ["&"] = 5,
   ["=="] = 6, ["!="] = 6,
   ["<"] = 7, [">"] = 7, ["<="] = 7, [">="] = 7,
   ["<<"] = 8, [">>"] = 8,
   ["+"] = 9, ["-"] = 9,
   ["*"] = 10, ["/"] = 10, ["%"] = 10,
}

local function eval_expr(tokens: {lexer.Token}, state: PPState): integer
   local mgr = state.mgr
   local idx = 1

   local function cur_lx(): StringView
      local t = tokens[idx]
      if t is nil then
         return EMPTY_VIEW
      end
      return get_lexeme(mgr, t)
   end

   local function cur_token(): lexer.Token | nil
      return tokens[idx]
   end

   local function advance()
      idx = idx + 1
   end

   local parse_expression: function(integer): integer

   local function parse_primary(): integer
      local t = cur_token()
      if t is nil then return 0 end
      local lx = cur_lx()
      if view_eq(lx, "defined") then
         advance()
         local next_tok = cur_token()
         local name_tok: lexer.Token | nil = nil
         if next_tok and lexeme_eq(mgr, next_tok, "(") then
            advance()
            name_tok = cur_token()
            advance()
            if cur_token() and lexeme_eq(mgr, cur_token() as lexer.Token, ")") then
               advance()
            end
         else
            name_tok = next_tok
            advance()
         end
         if name_tok then
            return eval_defined(lexeme_to_string(get_lexeme(mgr, name_tok)), state)
         end
         return 0
      elseif t.kind == lexer.K_NUMBER then
         advance()
         return parse_int_literal(lexeme_to_string(lx))
      elseif t.kind == lexer.K_CHAR then
         advance()
         return parse_char_literal(lexeme_to_string(lx))
      elseif t.kind == lexer.K_IDENTIFIER then
         advance()
         return 0
      elseif t.kind == lexer.K_PUNCT and view_eq(lx, "(") then
         advance()
         local v = parse_expression(0)
         if cur_token() and lexeme_eq(mgr, cur_token() as lexer.Token, ")") then
            advance()
         end
         return v
      else
         advance()
         return 0
      end
   end

   local function parse_unary(): integer
      local t = cur_token()
      if t is nil then return 0 end
      local lx = cur_lx()
      if view_eq(lx, "!") then
         advance()
         return parse_unary() == 0 and 1 or 0
      elseif view_eq(lx, "~") then
         advance()
         return bit.bxor(parse_unary(), -1)
      elseif view_eq(lx, "+") then
         advance()
         return parse_unary()
      elseif view_eq(lx, "-") then
         advance()
         return -parse_unary()
      else
         return parse_primary()
      end
   end

   function parse_expression(min_prec: integer): integer
      local lhs = parse_unary()
      while true do
         local t = cur_token()
         if t is nil then break end
         local op_view = cur_lx()
         local op = lexeme_to_string(op_view)
         local prec = binary_prec[op]
         if prec is nil or prec < min_prec then
            break
         end
         advance()
         local rhs = parse_expression(prec + 1)
         if op == "||" then
            lhs = (lhs ~= 0 or rhs ~= 0) and 1 or 0
         elseif op == "&&" then
            lhs = (lhs ~= 0 and rhs ~= 0) and 1 or 0
         elseif op == "|" then
            lhs = bit.bor(lhs, rhs)
         elseif op == "^" then
            lhs = bit.bxor(lhs, rhs)
         elseif op == "&" then
            lhs = bit.band(lhs, rhs)
         elseif op == "==" then
            lhs = lhs == rhs and 1 or 0
         elseif op == "!=" then
            lhs = lhs ~= rhs and 1 or 0
         elseif op == "<" then
            lhs = lhs < rhs and 1 or 0
         elseif op == ">" then
            lhs = lhs > rhs and 1 or 0
         elseif op == "<=" then
            lhs = lhs <= rhs and 1 or 0
         elseif op == ">=" then
            lhs = lhs >= rhs and 1 or 0
         elseif op == "<<" then
            lhs = bit.lshift(lhs, rhs)
         elseif op == ">>" then
            lhs = bit.rshift(lhs, rhs)
         elseif op == "+" then
            lhs = lhs + rhs
         elseif op == "-" then
            lhs = lhs - rhs
         elseif op == "*" then
            lhs = lhs * rhs
         elseif op == "/" then
            lhs = rhs ~= 0 and math.floor(lhs / rhs) or 0
         elseif op == "%" then
            lhs = rhs ~= 0 and (lhs % rhs) or 0
         end
      end
      return lhs
   end

   return parse_expression(0)
end

local function expand_expr_tokens(tokens: TokenVector, state: PPState): TokenVector
   local current = tokens
   local mgr = state.mgr
   local changed = true
   while changed do
      changed = false
      local out = new_token_vector()
      local ptr = current.data
      local idx = 0
      while idx < current.size do
      local tok = ptr[idx]
      local tok_view = get_lexeme(mgr, tok)
      if tok.kind == lexer.K_IDENTIFIER and not view_eq(tok_view, "defined") then
         local macro_idx = macro_index(state, tok)
            if macro_idx > 0 then
               local macro = state.macros[macro_idx]
               if not macro.is_function then
                  if state.expanding[macro.name] then
                     vec_push(out, tok)
                  else
                     state.expanding[macro.name] = true
                     changed = true
                     if macro.built_in then
                        local expanded = expand_builtin(macro, tok, state)
                        local eptr = expanded.data
                        for j = 0, expanded.size - 1 do
                           vec_push(out, eptr[j])
                        end
                     else
                        local expanded = substitute_macro(macro, {}, state)
                        local eptr = expanded.data
                        for j = 0, expanded.size - 1 do
                           vec_push(out, eptr[j])
                        end
                     end
                     state.expanding[macro.name] = nil
                  end
               else
                  vec_push(out, tok)
               end
            else
               vec_push(out, tok)
            end
         else
            vec_push(out, tok)
         end
         idx = idx + 1
      end
      current = out
   end
   return current
end

local function parse_include_target(tokens: TokenVector, mgr: SourceManager): string | nil, boolean
   if tokens.size == 0 then return nil, false end
   local ptr = tokens.data
   local first = ptr[0]
   
   if first.kind == lexer.K_STRING then
      local s = lexeme_to_string(get_lexeme(mgr, first))
      return s:sub(2, -2), false -- strip quotes
   elseif first.kind == lexer.K_PUNCT and lexeme_eq(mgr, first, "<") then
      local pieces: {string} = {}
      for i = 1, tokens.size - 1 do
         local t = ptr[i]
         if t.kind == lexer.K_PUNCT and lexeme_eq(mgr, t, ">") then
            break
         end
         pieces[#pieces + 1] = lexeme_to_string(get_lexeme(mgr, t))
      end
      return table.concat(pieces), true
   end
   return nil, false
end

local function handle_directive(source: TokenSource, state: PPState, directive_line: integer, stack: {TokenSource})
   local line_tokens = new_token_vector()
   while true do
      local t = source.peek()
      if t.kind == lexer.K_EOF or t.line > directive_line then
         break
      end
      vec_push(line_tokens, t)
      source.next()
   end
   if line_tokens.size == 0 then return end

   local ptr = line_tokens.data
   local dir_tok = ptr[0]
   if dir_tok.kind ~= lexer.K_IDENTIFIER and dir_tok.kind ~= lexer.K_KEYWORD then
      return
   end

   local name_view = get_lexeme(state.mgr, dir_tok)
   local active = state.active
   if view_eq(name_view, "define") then
      if not active then return end
      local def_tokens = new_token_vector()
      for i = 1, line_tokens.size - 1 do
         vec_push(def_tokens, ptr[i])
      end
      parse_define(def_tokens, state)
      recycle_vector(def_tokens)
   elseif view_eq(name_view, "undef") then
      if not active then return end
      if line_tokens.size > 1 then
         local uname = lexeme_to_string(get_lexeme(state.mgr, ptr[1]))
         remove_macro(state, uname)
      end
   elseif view_eq(name_view, "include") then
      if not active then return end
      local inc_tokens = new_token_vector()
      for i = 1, line_tokens.size - 1 do
         vec_push(inc_tokens, ptr[i])
      end
      local path, is_angle = parse_include_target(inc_tokens, state.mgr)
      recycle_vector(inc_tokens)
      if path then
         local cur_path = state.mgr.paths[dir_tok.file_id] or state.opts.current_dir or ""
         local resolved = resolve_include(path, is_angle, state, cur_path)
         if resolved then
            if state.once_paths[resolved] then
               return
            end
            local new_src = read_file(resolved)
            if new_src then
               local file_id = next_file_id(state.mgr)
               local inc_source = new_lexer_source(new_src, file_id, state.mgr, resolved)
               stack[#stack + 1] = inc_source
            end
         end
      end
   elseif view_eq(name_view, "pragma") then
      if not active then return end
      if line_tokens.size > 1 and lexeme_eq(state.mgr, ptr[1], "once") then
         local info = ensure_source_info(state.mgr, dir_tok.file_id)
         if info.path ~= "" then
            state.once_paths[info.path] = true
         end
      end
   elseif view_eq(name_view, "if") then
      local parent_active = state.active
      local expr_tokens = new_token_vector()
      for i = 1, line_tokens.size - 1 do
         vec_push(expr_tokens, ptr[i])
      end
      local expanded = expand_expr_tokens(expr_tokens, state)
      local expr_list: {lexer.Token} = {}
      local eptr = expanded.data
      for i = 0, expanded.size - 1 do
         expr_list[#expr_list + 1] = eptr[i]
      end
      local cond_val = eval_expr(expr_list, state) ~= 0
      recycle_vector(expanded)
      recycle_vector(expr_tokens)
      local new_active = parent_active and cond_val
      table.insert(state.cond_stack, { parent_active = parent_active, taken = new_active, else_seen = false })
      state.active = new_active
   elseif view_eq(name_view, "ifdef") or view_eq(name_view, "ifndef") then
      local parent_active = state.active
      local cond = false
      if line_tokens.size > 1 then
         local lname = lexeme_to_string(get_lexeme(state.mgr, ptr[1]))
         cond = is_macro_defined(state, lname)
      end
      if view_eq(name_view, "ifndef") then
         cond = not cond
      end
      local new_active = parent_active and cond
      table.insert(state.cond_stack, { parent_active = parent_active, taken = new_active, else_seen = false })
      state.active = new_active
   elseif view_eq(name_view, "elif") then
      if #state.cond_stack == 0 then return end
      local frame = state.cond_stack[#state.cond_stack]
      if frame.else_seen then
         return
      end
      local cond = false
      if not frame.taken and frame.parent_active then
         local expr_tokens = new_token_vector()
         for i = 1, line_tokens.size - 1 do
            vec_push(expr_tokens, ptr[i])
         end
         local expanded = expand_expr_tokens(expr_tokens, state)
         local expr_list: {lexer.Token} = {}
         local eptr = expanded.data
         for i = 0, expanded.size - 1 do
            expr_list[#expr_list + 1] = eptr[i]
         end
         cond = eval_expr(expr_list, state) ~= 0
         recycle_vector(expanded)
         recycle_vector(expr_tokens)
      end
      local new_active = frame.parent_active and (not frame.taken) and cond
      frame.taken = frame.taken or new_active
      state.active = new_active
   elseif view_eq(name_view, "else") then
      if #state.cond_stack == 0 then return end
      local frame = state.cond_stack[#state.cond_stack]
      if frame.else_seen then
         return
      end
      local new_active = frame.parent_active and not frame.taken
      frame.taken = frame.taken or new_active
      frame.else_seen = true
      state.active = new_active
   elseif view_eq(name_view, "endif") then
      if #state.cond_stack == 0 then return end
      local frame = table.remove(state.cond_stack)
      state.active = frame.parent_active
   elseif view_eq(name_view, "error") then
      if not active then return end
      local msg_parts: {string} = {}
      for i = 1, line_tokens.size - 1 do
         msg_parts[#msg_parts + 1] = lexeme_to_string(get_lexeme(state.mgr, ptr[i]))
      end
      local msg = table.concat(msg_parts, " ")
      state.reporter:report(Diagnostic.new("error", msg, dir_tok:span(), "PP300"))
   elseif view_eq(name_view, "line") then
      if not active then return end
      if line_tokens.size > 1 then
         local num = tonumber(lexeme_to_string(get_lexeme(state.mgr, ptr[1]))) or dir_tok.line
         local info = ensure_source_info(state.mgr, dir_tok.file_id)
         info.line_delta = (num - (directive_line + 1)) as integer
         if line_tokens.size > 2 and ptr[2].kind == lexer.K_STRING then
            local lx = lexeme_to_string(get_lexeme(state.mgr, ptr[2]))
            local stripped = lx:sub(2, -2)
            info.path = stripped
            state.mgr.paths[dir_tok.file_id] = stripped
         end
      end
   end
   recycle_vector(line_tokens)
end

local function preprocess(src: string, file_id: integer, reporter: Reporter, opts?: PPOptions): TokenSource
   local mgr: SourceManager = {
      sources = {},
      ptrs = {},
      buffers = {},
      paths = {},
      infos = {},
      next_id = file_id + 1,
   }
   local options: PPOptions = opts or {}
   local refs: {any} = {}
   local state: PPState = {
      macros = {},
      macro_table = new_macro_table(4096, refs),
      macro_refs = refs,
      macro_map = {},
      mgr = mgr,
       reporter = reporter,
       once_paths = {},
       cond_stack = {},
       active = true,
       expanding = {},
       opts = options,
      date_literal = os.date("%b %d %Y"),
      time_literal = os.date("%H:%M:%S"),
   }
   install_builtins(state)
   local defns: {string:string} | nil = options.defines
   if not defns is nil then
      for name, val in pairs(defns) do
         local value = (val ~= "" and val) and val or "1"
         define_object_macro(state, name, { make_synthetic_token(mgr, value, lexer.K_NUMBER) })
      end
   end
   local undefs: {string:boolean} | nil = options.undefs
   if not undefs is nil then
      for name, _ in pairs(undefs) do
         remove_macro(state, name)
      end
   end
   
   register_source(mgr, file_id, src, options.source_path or "")
   ensure_source_info(mgr, file_id)
   local initial_source = new_lexer_source(src, file_id, mgr, options.source_path)
   local stack: {TokenSource} = { initial_source }
   local emit_block_size<const> = 4096
   local emit_blocks: {ffi.Array<lexer.Token>} = { ffi.new("tl_token_fast[?]", emit_block_size) }
   local emit_idx = 0

   local function emit(tok: lexer.Token): lexer.Token
      local block = emit_blocks[#emit_blocks]
      if emit_idx >= emit_block_size then
         block = ffi.new("tl_token_fast[?]", emit_block_size)
         emit_blocks[#emit_blocks + 1] = block
         emit_idx = 0
      end
      ffi_copy(block + emit_idx, tok, TOKEN_SIZE)
      local out = block[emit_idx]
      emit_idx = emit_idx + 1
      return out
   end
   
   local function next_token(): lexer.Token
      while #stack > 0 do
         local top = stack[#stack]
         local tok = top.peek() -- Peek first to check for directive
         
         if tok.kind == lexer.K_EOF then
            top.next() -- Consume EOF
            if top.vec then
               recycle_vector(top.vec)
            end
            if top.macro_name then
               state.expanding[top.macro_name] = nil
            end
            table.remove(stack)
         elseif top.is_file and tok.kind == lexer.K_PUNCT and lexeme_eq(mgr, tok, "#") then
             top.next() -- Consume '#'
             handle_directive(top, state, tok.line, stack)
      elseif not state.active then
         top.next()
      elseif tok.kind == lexer.K_IDENTIFIER then
         top.next() -- Consume identifier
         local macro_idx = macro_index(state, tok)
         
             local macro: MacroC = nil
             if macro_idx > 0 then
                 macro = state.macros[macro_idx]
             end

             if macro then
             if macro.is_function then
                  local next_tok = top.peek()
                  if next_tok.kind == lexer.K_PUNCT and lexeme_eq(mgr, next_tok, "(") then
                     if state.expanding[macro.name] then
                         return tok
                     end
                     state.expanding[macro.name] = true
                     local args = parse_macro_args(top, mgr)
                      local expanded = substitute_macro(macro, args, state)
                     recycle_args(args)
                     stack[#stack + 1] = new_vector_source(expanded, macro.name)
                  else
                      return emit(tok)
                   end
                else
                   if state.expanding[macro.name] then
                      return emit(tok)
                   end
                   state.expanding[macro.name] = true
                   local expanded: TokenVector
                   if macro.built_in then
                      expanded = expand_builtin(macro, tok, state)
                   else
                      expanded = substitute_macro(macro, {}, state)
                   end
                   stack[#stack + 1] = new_vector_source(expanded, macro.name)
                end
             else
                return emit(tok)
             end
        else
            top.next() -- Consume
            return emit(tok)
        end
     end
      
      local eof: lexer.Token = ffi.new("tl_token_fast")
      eof.kind = lexer.K_EOF
      return eof
   end
   
   return {
      next = next_token,
      peek = function(): lexer.Token
         if #stack == 0 then
            local eof: lexer.Token = ffi.new("tl_token_fast")
            eof.kind = lexer.K_EOF
            return eof
         end
         return stack[#stack].peek()
      end,
      is_file = false,
      lexer = initial_source.lexer,
      mgr = mgr,
      macro_name = nil,
      vec = nil,
   }
end


return {
   new_lexer_source = new_lexer_source,
   get_lexeme = get_lexeme,
   lexeme_to_string = lexeme_to_string,
   preprocess = preprocess,
   parse_define = parse_define,
   parse_macro_args = parse_macro_args,
   substitute_macro = substitute_macro,
}
