local ffi = require("ffi")
local bit = require("bit")
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

local type TokenKind = integer
local type TokenFlags = integer

-- Token Kinds
local K_UNKNOWN = 0
local K_IDENTIFIER = 1
local K_NUMBER = 2
local K_STRING = 3
local K_CHAR = 4
local K_KEYWORD = 5
local K_PUNCT = 6
local K_EOF = 7
local K_COMMENT = 8
local K_WHITESPACE = 9

-- Token Flags
local TOKEN_FLAG_NEWLINE = 1
local TOKEN_FLAG_LEADING_SPACE = 2

-- FFI Definitions
ffi.cdef[[
typedef struct {
  uint32_t start;      /* 0-based */
  uint32_t stop;       /* exclusive */
  uint32_t line;       /* 1-based */
  uint32_t col;        /* 1-based */
  uint8_t kind;        /* TokenKindId */
  uint8_t flags;       /* TokenFlags */
} tl_token_fast;
]]

-- Custom FFI Records for Type Safety
local record TokenC is ffi.CData
   where ffi.istype("tl_token_fast", self)
   start: integer
   stop: integer
   line: integer
   col: integer
   kind: integer
   flags: integer
end

local type TokenPtr = ffi.Pointer<TokenC>

local record Uint8Array is {integer}, ffi.CData
end

local type Uint8Ptr = ffi.Pointer<integer>

local TokenArrayType = ffi.typeof("tl_token_fast[?]")
local TokenType = ffi.typeof("tl_token_fast")

local record LexBuffer
   data: TokenPtr
   count: integer
   cap: integer
   src: string
   src_ptr: Uint8Ptr
   file_id: integer
   lexeme_cache: {string}
end

-- Character Properties Lookup Table (FFI)
local PROP_SPACE = 1
local PROP_DIGIT = 2
local PROP_ALPHA = 4
local PROP_IDENT = 8 -- ALPHA | DIGIT | _
local PROP_HEX = 16

local char_props_c = ffi.new("uint8_t[256]") as Uint8Array
local function init_char_props()
   for i = 0, 255 do
      local p = 0
      if (i >= 9 and i <= 13) or i == 32 then p = bor(p, PROP_SPACE) end
      if i >= 48 and i <= 57 then p = bor(p, bor(PROP_DIGIT, bor(PROP_IDENT, PROP_HEX))) end
      if (i >= 65 and i <= 90) or (i >= 97 and i <= 122) then p = bor(p, bor(PROP_ALPHA, PROP_IDENT)) end
      if (i >= 65 and i <= 70) or (i >= 97 and i <= 102) then p = bor(p, PROP_HEX) end
      if i == 95 then p = bor(p, bor(PROP_IDENT, PROP_ALPHA)) end -- _ is alpha-like for start
      char_props_c[i] = p
   end
end
init_char_props()

-- Punctuator Max Length Lookup (FFI)
local punct_max_len_c = ffi.new("uint8_t[256]") as Uint8Array
local punctuators: {string:boolean} = {}
local function add_punct(s: string)
   punctuators[s] = true
   local first = string.byte(s, 1)
   if #s > punct_max_len_c[first] then
      punct_max_len_c[first] = #s
   end
end

local punct_list = {
   "+", "-", "*", "/", "%", "^", "&", "|", "~", "!", "=", "<", ">", "?",
   "++", "--",
   "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "<<=", ">>=",
   "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "->", ".", ",", ";", ":",
   "(", ")", "[", "]", "{", "}", "...", "##", "#"
}
for _, p in ipairs(punct_list) do add_punct(p) end

local keywords: {string:boolean} = {
   ["auto"] = true, ["break"] = true, ["case"] = true, ["char"] = true,
   ["const"] = true, ["continue"] = true, ["default"] = true, ["do"] = true,
   ["double"] = true, ["else"] = true, ["enum"] = true, ["extern"] = true,
   ["float"] = true, ["for"] = true, ["goto"] = true, ["if"] = true,
   ["int"] = true, ["long"] = true, ["register"] = true, ["return"] = true,
   ["short"] = true, ["signed"] = true, ["sizeof"] = true, ["static"] = true,
   ["struct"] = true, ["switch"] = true, ["typedef"] = true, ["union"] = true,
   ["unsigned"] = true, ["void"] = true, ["volatile"] = true, ["while"] = true,
   ["_Bool"] = true, ["_Complex"] = true, ["_Imaginary"] = true, ["inline"] = true,
   ["restrict"] = true, ["_Alignas"] = true, ["_Alignof"] = true, ["_Atomic"] = true,
   ["_Generic"] = true, ["_Noreturn"] = true, ["_Static_assert"] = true, ["_Thread_local"] = true,
}

local function lex(source: string, file_id: integer): LexBuffer
   local len = #source
   local ptr = ffi.cast("const uint8_t*", source) as Uint8Ptr
   local buf_cap = 4096
   local buf_data = ffi.new(TokenArrayType, buf_cap) as TokenPtr
   local buf_count = 0
   
   -- Localize FFI pointers for speed
   local cp = char_props_c
   local pml = punct_max_len_c
   
   local pos = 0
   local line = 1
   local col = 1
   local start_pos = 0
   local start_col = 0
   local newline_flag = 0 -- 0 or TOKEN_FLAG_NEWLINE

   -- Helper to grow buffer
   local function grow()
      local new_cap = buf_cap * 2
      local new_data = ffi.new(TokenArrayType, new_cap) as TokenPtr
      (ffi.copy as function(any, any, integer))(new_data, buf_data, buf_cap * ffi.sizeof(TokenType))
      buf_data = new_data
      buf_cap = new_cap
   end

   -- Helper to push token
   local function push(kind: integer, start: integer, stop: integer, l: integer, c: integer, flags: integer)
      buf_count = buf_count + 1
      if buf_count >= buf_cap then grow() end
      local t = buf_data[buf_count]
      t.kind = kind
      t.start = start
      t.stop = stop
      t.line = l
      t.col = c
      t.flags = flags
   end

   while pos < len do
      local c = ptr[pos]
      
      -- Fast Skip Whitespace
      if band(cp[c], PROP_SPACE) ~= 0 then
         newline_flag = 0
         repeat
            if c == 10 then -- \n
               line = line + 1
               col = 1
               newline_flag = TOKEN_FLAG_NEWLINE
            else
               col = col + 1
            end
            pos = pos + 1
            if pos >= len then break end
            c = ptr[pos]
         until band(cp[c], PROP_SPACE) == 0
         if pos >= len then break end
      end

      start_pos = pos
      start_col = col
      
      -- Identifier / Keyword
      if band(cp[c], PROP_ALPHA) ~= 0 or c == 95 then -- _
         repeat
            pos = pos + 1
            col = col + 1
            if pos >= len then break end
            c = ptr[pos]
         until band(cp[c], PROP_IDENT) == 0
         
         local s = ffi.string(ptr + start_pos, pos - start_pos)
         local kind = keywords[s] and K_KEYWORD or K_IDENTIFIER
         
         push(kind, start_pos, pos, line, start_col, newline_flag)
         newline_flag = 0
         
      -- Number
      elseif band(cp[c], PROP_DIGIT) ~= 0 then
         -- Simple number scan
         repeat
            pos = pos + 1
            col = col + 1
            if pos >= len then break end
            c = ptr[pos]
         until band(cp[c], PROP_IDENT) == 0 and c ~= 46 and c ~= 43 and c ~= 45
         
         -- Re-scan for correctness
         pos = start_pos
         col = start_col
         c = ptr[pos]
         
         if c == 48 and pos + 1 < len and (ptr[pos+1] == 120 or ptr[pos+1] == 88) then -- 0x
            pos = pos + 2
            col = col + 2
            while pos < len do
               c = ptr[pos]
               if band(cp[c], PROP_HEX) ~= 0 or band(cp[c], PROP_DIGIT) ~= 0 then
                  pos = pos + 1; col = col + 1
               else
                  break
               end
            end
         else
            while pos < len do
               c = ptr[pos]
               if band(cp[c], PROP_DIGIT) ~= 0 then
                  pos = pos + 1; col = col + 1
               else
                  break
               end
            end
         end
         -- Fraction
         if pos < len and ptr[pos] == 46 then -- .
            pos = pos + 1; col = col + 1
            while pos < len do
               c = ptr[pos]
               if band(cp[c], PROP_DIGIT) ~= 0 then
                  pos = pos + 1; col = col + 1
               else
                  break
               end
            end
         end
         -- Exponent
         if pos < len then
            c = ptr[pos]
            if c == 101 or c == 69 or c == 112 or c == 80 then -- e E p P
               pos = pos + 1; col = col + 1
               if pos < len and (ptr[pos] == 43 or ptr[pos] == 45) then -- + -
                  pos = pos + 1; col = col + 1
               end
               while pos < len do
                  c = ptr[pos]
                  if band(cp[c], PROP_DIGIT) ~= 0 then
                     pos = pos + 1; col = col + 1
                  else
                     break
                  end
               end
            end
         end
         -- Suffix
         while pos < len do
            c = ptr[pos]
            if c == 117 or c == 85 or c == 108 or c == 76 or c == 102 or c == 70 then -- u U l L f F
               pos = pos + 1; col = col + 1
            else
               break
            end
         end
         
         push(K_NUMBER, start_pos, pos, line, start_col, newline_flag)
         newline_flag = 0

      -- String / Char
      elseif c == 34 or c == 39 or (c == 76 and pos + 1 < len and (ptr[pos+1] == 34 or ptr[pos+1] == 39)) then
         local quote = c
         local kind = K_STRING
         if c == 76 then -- L"..."
            pos = pos + 1; col = col + 1
            quote = ptr[pos]
         end
         if quote == 39 then kind = K_CHAR end
         
         pos = pos + 1; col = col + 1 -- skip quote
         
         while pos < len do
            c = ptr[pos]
            if c == quote then
               pos = pos + 1; col = col + 1
               break
            elseif c == 92 then -- \
               pos = pos + 2; col = col + 2 -- skip escaped char
            elseif c == 10 then -- newline in string?
               line = line + 1; col = 1; pos = pos + 1
            else
               pos = pos + 1; col = col + 1
            end
         end
         
         push(kind, start_pos, pos, line, start_col, newline_flag)
         newline_flag = 0

      -- Comments / Punctuation
      elseif c == 47 then -- /
         local next_c = (pos + 1 < len) and ptr[pos+1] or 0
         if next_c == 47 then -- //
            pos = pos + 2; col = col + 2
            while pos < len do
               c = ptr[pos]
               if c == 10 then break end
               pos = pos + 1
            end
            newline_flag = 0 
         elseif next_c == 42 then -- /*
            pos = pos + 2; col = col + 2
            while pos < len do
               c = ptr[pos]
               if c == 42 and pos + 1 < len and ptr[pos+1] == 47 then
                  pos = pos + 2; col = col + 2
                  break
               end
               if c == 10 then
                  line = line + 1; col = 1
               else
                  col = col + 1
               end
               pos = pos + 1
            end
            newline_flag = 0 
         else
            -- Punctuation /
            local max_l = pml[c]
            local matched = false
            if max_l > 1 then
                if max_l >= 2 and pos + 1 < len then
                   local c2 = ptr[pos+1]
                   if c2 == 61 then -- =
                      matched = true; pos = pos + 2; col = col + 2
                   end
                end
            end
            
            if not matched then
               pos = pos + 1
               col = col + 1
            end
            
            push(K_PUNCT, start_pos, pos, line, start_col, newline_flag)
            newline_flag = 0
         end
         
      else
         -- Punctuation
         local max_l = pml[c]
         local matched = false
         if max_l > 1 then
             if max_l >= 3 and pos + 2 < len then
                local c2 = ptr[pos+1]
                local c3 = ptr[pos+2]
                if c == 60 and c2 == 60 and c3 == 61 then matched = true; pos = pos + 3; col = col + 3 end
                if c == 62 and c2 == 62 and c3 == 61 then matched = true; pos = pos + 3; col = col + 3 end
                if c == 46 and c2 == 46 and c3 == 46 then matched = true; pos = pos + 3; col = col + 3 end
             end
             if not matched and max_l >= 2 and pos + 1 < len then
                local c2 = ptr[pos+1]
                if c2 == 61 then -- =
                   if c == 43 or c == 45 or c == 42 or c == 47 or c == 37 or c == 94 or c == 38 or c == 124 or c == 61 or c == 33 or c == 60 or c == 62 then
                      matched = true; pos = pos + 2; col = col + 2
                   end
                elseif c == 45 and c2 == 62 then matched = true; pos = pos + 2; col = col + 2 -- ->
                elseif c == 43 and c2 == 43 then matched = true; pos = pos + 2; col = col + 2 -- ++
                elseif c == 45 and c2 == 45 then matched = true; pos = pos + 2; col = col + 2 -- --
                elseif c == 38 and c2 == 38 then matched = true; pos = pos + 2; col = col + 2 -- &&
                elseif c == 124 and c2 == 124 then matched = true; pos = pos + 2; col = col + 2 -- ||
                elseif c == 60 and c2 == 60 then matched = true; pos = pos + 2; col = col + 2 -- <<
                elseif c == 62 and c2 == 62 then matched = true; pos = pos + 2; col = col + 2 -- >>
                elseif c == 35 and c2 == 35 then matched = true; pos = pos + 2; col = col + 2 -- ##
                end
             end
         end
         
         if not matched then
            pos = pos + 1
            col = col + 1
         end
         
         push(K_PUNCT, start_pos, pos, line, start_col, newline_flag)
         newline_flag = 0
      end
   end
   
   push(K_EOF, pos, pos, line, col, 0)

   return {
      data = buf_data,
      count = buf_count,
      cap = buf_cap,
      src = source,
      src_ptr = ptr,
      file_id = file_id,
      lexeme_cache = {},
   }
end

local function lexeme(buf: LexBuffer, idx: integer): string
   local t = buf.data[idx]
   local cache = buf.lexeme_cache
   if not cache[idx] then
      cache[idx] = ffi.string(buf.src_ptr + t.start, t.stop - t.start)
   end
   return cache[idx]
end

return {
   lex = lex,
   lexeme = lexeme,
   LexBuffer = LexBuffer,
   TokenKind = TokenKind,
   TokenFlags = TokenFlags,
   K_UNKNOWN = K_UNKNOWN,
   K_IDENTIFIER = K_IDENTIFIER,
   K_NUMBER = K_NUMBER,
   K_STRING = K_STRING,
   K_CHAR = K_CHAR,
   K_KEYWORD = K_KEYWORD,
   K_PUNCT = K_PUNCT,
   K_EOF = K_EOF,
   K_COMMENT = K_COMMENT,
   K_WHITESPACE = K_WHITESPACE,
   TOKEN_FLAG_NEWLINE = TOKEN_FLAG_NEWLINE,
   TOKEN_FLAG_LEADING_SPACE = TOKEN_FLAG_LEADING_SPACE,
}
