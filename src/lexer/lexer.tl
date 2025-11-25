local ffi = require("ffi")
local bit = require("bit")
local Span = require("util.span")
local band = bit.band
local bor = bit.bor

local type TokenKind = integer
local type TokenFlags = integer

-- Token Kinds
local K_UNKNOWN<const> = 0
local K_IDENTIFIER<const> = 1
local K_NUMBER<const> = 2
local K_STRING<const> = 3
local K_CHAR<const> = 4
local K_KEYWORD<const> = 5
local K_PUNCT<const> = 6
local K_EOF<const> = 7
local K_COMMENT<const> = 8
local K_WHITESPACE<const> = 9

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
  uint32_t file_id;    /* File ID */
  uint8_t kind;        /* TokenKindId */
  uint8_t flags;       /* TokenFlags */
} tl_token_fast;
]]

local record TokenC is ffi.CData
   where ffi.istype("tl_token_fast", self)
   start: integer
   stop: integer
   line: integer
   col: integer
   file_id: integer
   kind: integer
   flags: integer
end

local type Uint8Array = ffi.Array<integer>
local type Uint8Ptr = ffi.CString

local TokenType = ffi.typeof("tl_token_fast")

local record LexerState
   src: string
   src_ptr: Uint8Ptr
   len: integer
   pos: integer
   line: integer
   col: integer
   file_id: integer
   newline_flag: integer
   current_token: TokenC
end

-- Character Properties Lookup Table (FFI)
local PROP_SPACE<const> = 1
local PROP_DIGIT<const> = 2
local PROP_ALPHA<const> = 4
local PROP_IDENT<const> = 8 -- ALPHA | DIGIT | _
local PROP_HEX<const> = 16

local char_props_c: Uint8Array = ffi.new("uint8_t[256]")
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

local punct_max_len_c: Uint8Array = ffi.new("uint8_t[256]")
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

-- ffi.cdef [[
-- bool is_keyword_c(const unsigned char *s, int len);
-- ]]
-- local fastcmp = ffi.load(os.getenv("LIBFASTCMP") or "fastcmp")
-- local macroexp is_keyword_c(s: Uint8Ptr, len: integer): boolean
--    return (fastcmp.is_keyword_c as function(ffi.CData, integer))(s, len)
-- end

ffi.cdef [[
int memcmp(const void *s1, const void *s2, size_t n);
int strlen(const char *s);
]]
local C = ffi.C

local macroexp is_kw(s: Uint8Ptr, kw: string, kwlen: integer): boolean
   return (C.memcmp as function(ffi.CData, ffi.String, integer))(s, kw, kwlen) == 0
end

local function is_keyword_c(s: Uint8Ptr, len: integer): boolean
   if len < 2 or len > 15 then
      return false
   end

   local c0 = s[0]

   -- len == 2
   if len == 2 then
      local c1 = s[1]
      return (c0 == 100 and c1 == 111) or      -- do
             (c0 == 105 and c1 == 102)         -- if

   -- len == 3
   elseif len == 3 then
      return (c0 == 102 and s[1] == 111 and s[2] == 114) or  -- for
             (c0 == 105 and s[1] == 110 and s[2] == 116)     -- int

   -- len == 4
   elseif len == 4 then
      local c1, c2, c3 = s[1], s[2], s[3]
      -- auto / case / char / else / enum / goto / long / void
      if c0 == 97 then         -- 'a'
         return c1 == 117 and c2 == 116 and c3 == 111         -- auto
      elseif c0 == 99 then     -- 'c'
         return (c1 == 97 and c2 == 115 and c3 == 101) or     -- case
                (c1 == 104 and c2 == 97 and c3 == 114)        -- char
      elseif c0 == 101 then    -- 'e'
         return (c1 == 108 and c2 == 115 and c3 == 101) or    -- else
                (c1 == 110 and c2 == 117 and c3 == 109)       -- enum
      elseif c0 == 103 then    -- 'g'
         return c1 == 111 and c2 == 116 and c3 == 111         -- goto
      elseif c0 == 108 then    -- 'l'
         return c1 == 111 and c2 == 110 and c3 == 103         -- long
      elseif c0 == 118 then    -- 'v'
         return c1 == 111 and c2 == 105 and c3 == 100         -- void
      else
         return false
      end

   -- len == 5
   elseif len == 5 then
      local c1, c2, c3, c4 = s[1], s[2], s[3], s[4]
      return (c0 == 98 and c1 == 114 and c2 == 101 and c3 == 97 and c4 == 107) or -- break
             (c0 == 99 and c1 == 111 and c2 == 110 and c3 == 115 and c4 == 116) or -- const
             (c0 == 102 and c1 == 108 and c2 == 111 and c3 == 97 and c4 == 116) or -- float
             (c0 == 115 and c1 == 104 and c2 == 111 and c3 == 114 and c4 == 116) or -- short
             (c0 == 119 and c1 == 104 and c2 == 105 and c3 == 108 and c4 == 101)    -- while

   -- len == 6
   elseif len == 6 then
      -- double, extern, return, sizeof, static, struct, switch, inline
      if c0 == 100 then
         return is_kw(s, "double", 6)
      elseif c0 == 101 then
         return is_kw(s, "extern", 6)
      elseif c0 == 114 then
         return is_kw(s, "return", 6)
      elseif c0 == 115 then
         return is_kw(s, "sizeof", 6) or is_kw(s, "static", 6) or is_kw(s, "struct", 6) or is_kw(s, "switch", 6)
      elseif c0 == 105 then
         return is_kw(s, "inline", 6)
      else
         return false
      end

   -- len == 7
   elseif len == 7 then
      -- typedef, volatile
      if c0 == 116 then
         return is_kw(s, "typedef", 7)
      elseif c0 == 118 then
         return is_kw(s, "volatile", 7)
      else
         return false
      end

   -- len == 8
   elseif len == 8 then
      -- continue, register, unsigned, _Complex, _Atomic
      if c0 == 99 then
         return is_kw(s, "continue", 8)
      elseif c0 == 114 then
         return is_kw(s, "register", 8)
      elseif c0 == 117 then
         return is_kw(s, "unsigned", 8)
      elseif c0 == 95 then
         return is_kw(s, "_Complex", 8) or is_kw(s, "_Atomic", 8)
      else
         return false
      end

   -- len == 9, 10, 11, 12, 13, etc.
   elseif len == 5 and c0 == 95 then
      return is_kw(s, "_Bool", 5)
   elseif len == 10 and c0 == 95 then
      -- _Alignas, _Alignof, _Noreturn
      return is_kw(s, "_Alignas", 8) or is_kw(s, "_Alignof", 8) or is_kw(s, "_Noreturn", 9)
   elseif len == 14 then
      return is_kw(s, "_Static_assert", 14)
   elseif len == 13 then
      return is_kw(s, "_Thread_local", 13)
   else
      return false
   end
end


local function new_lexer(source: string, file_id: integer): LexerState
   local len = #source

   return {
      src = source,
      src_ptr = ffi.cast("const uint8_t*", source),
      len = len,
      pos = 0,
      line = 1,
      col = 1,
      file_id = file_id,
      newline_flag = 0,
      current_token = ffi.new(TokenType)
   }
end

local function next_token(state: LexerState): TokenC
   local ptr = state.src_ptr
   local len = state.len
   local pos = state.pos
   local line = state.line
   local col = state.col
   local newline_flag = state.newline_flag
   
   local cp = char_props_c
   local pml = punct_max_len_c
   
   local start_pos = pos
   local start_col = col
   local kind: TokenKind = K_EOF
   ::scan::
   if pos >= len then
      kind = K_EOF
   else
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
         start_pos = pos
         start_col = col
         goto scan
      end

      -- String / Char (handles wide prefixes)
      if c == 34 or c == 39 or (c == 76 and pos + 1 < len and (ptr[pos+1] == 34 or ptr[pos+1] == 39)) then
         local quote = c
         kind = K_STRING
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

      -- Identifier / Keyword
      elseif band(cp[c], PROP_ALPHA) ~= 0 or c == 95 then -- _
         repeat
            pos = pos + 1
            col = col + 1
            if pos >= len then break end
            c = ptr[pos]
         until band(cp[c], PROP_IDENT) == 0
         
         -- local s = ffi.string(ptr + start_pos, pos - start_pos)
         -- kind = keywords[s] and K_KEYWORD or K_IDENTIFIER
         kind = is_keyword_c(ptr + start_pos, pos - start_pos) and K_KEYWORD or K_IDENTIFIER
      
      -- Number
      elseif band(cp[c], PROP_DIGIT) ~= 0 then
         repeat
            pos = pos + 1
            col = col + 1
            if pos >= len then break end
            c = ptr[pos]
         until band(cp[c], PROP_IDENT) == 0 and c ~= 46 and c ~= 43 and c ~= 45
         
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
         if pos < len and ptr[pos] == 46 then
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
         while pos < len do
            c = ptr[pos]
            if c == 117 or c == 85 or c == 108 or c == 76 or c == 102 or c == 70 then -- u U l L f F
               pos = pos + 1; col = col + 1
            else
               break
            end
         end
         
         kind = K_NUMBER

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
            goto scan
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
            goto scan
         else
            local max_l = pml[c]
            local matched = false
            if max_l > 1 then
                if max_l >= 2 and pos + 1 < len then
                   local c2 = ptr[pos+1]
                   if c2 == 61 then
                      matched = true; pos = pos + 2; col = col + 2
                   end
                end
            end
            
            if not matched then
               pos = pos + 1
               col = col + 1
            end
            
            kind = K_PUNCT
         end
         
      else
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
                if c2 == 61 then
                   if c == 43 or c == 45 or c == 42 or c == 47 or c == 37 or c == 94 or c == 38 or c == 124 or c == 61 or c == 33 or c == 60 or c == 62 then
                      matched = true; pos = pos + 2; col = col + 2
                   end
                elseif c == 45 and c2 == 62 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 43 and c2 == 43 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 45 and c2 == 45 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 38 and c2 == 38 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 124 and c2 == 124 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 60 and c2 == 60 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 62 and c2 == 62 then matched = true; pos = pos + 2; col = col + 2
                elseif c == 35 and c2 == 35 then matched = true; pos = pos + 2; col = col + 2
                end
             end
         end
         
         if not matched then
            pos = pos + 1
            col = col + 1
         end
         
         kind = K_PUNCT
      end
   end
   
   state.pos = pos
   state.line = line
   state.col = col
   state.newline_flag = 0
   
   local tok = state.current_token
   tok.file_id = state.file_id
   if kind == K_EOF then
      tok.kind = K_EOF
      tok.start = pos
      tok.stop = pos
      tok.line = line
      tok.col = col
      tok.flags = 0
      local eof_arr: ffi.Array<TokenC> = ffi.new("tl_token_fast[1]")
      ffi.copy(eof_arr, tok, ffi.sizeof("tl_token_fast"))
      return eof_arr[0]
   end

   tok.kind = kind
   tok.start = start_pos
   tok.stop = pos
   tok.line = line
   tok.col = start_col
   tok.flags = newline_flag
   local out_arr: ffi.Array<TokenC> = ffi.new("tl_token_fast[1]")
   ffi.copy(out_arr, tok, ffi.sizeof("tl_token_fast"))
   return out_arr[0]
end

ffi.cdef [[
struct tl_string_view {
   const uint8_t *ptr;
   uint32_t len;
};
]]
local TLStringView = ffi.typeof("struct tl_string_view") as function(ptr: Uint8Ptr, len: integer)

local record StringView is ffi.CData where ffi.istype("struct tl_string_view", self)
   ptr: Uint8Ptr
   len: integer

   metamethod __tostring: function(self): string
   metamethod __eq: function(self, other: ffi.CData): boolean
   metamethod __eq: function(self, other: string): boolean
   metamethod __len: function(self): integer = macroexp(self: self): integer return self.len end
   metamethod __concat: function(self, other: string): string
end

ffi.metatype("struct tl_string_view", {
   __tostring = function(self: StringView): string
      return ffi.string(self.ptr, self.len)
   end,
   __eq = function(self: StringView, other: ffi.CString | string | StringView): boolean
      local other_len: integer
      if other is string then
         other_len = #other
      elseif other is StringView then
         other_len = other.len
      else
         other_len = (C.strlen as function(ffi.CData): integer)(other)
      end

      if self.len ~= other_len then
         return false
      end
      return (C.memcmp as function(ffi.CData, ffi.CData | string, integer))(self.ptr, other, self.len) == 0
   end,

   __concat = function(self: string | StringView, other: string | StringView): string
      return tostring(self)..tostring(other)
   end,
})

function TokenC:lexeme(src: ffi.CString): StringView
   return ffi.new("struct tl_string_view", src + self.start, self.stop - self.start)
   -- return ffi.string(src + self.start, self.stop - self.start)
end

function TokenC:span(): Span
   return Span.new(self.file_id, self.start, self.stop, self.line, self.col)
end

ffi.metatype("tl_token_fast", {
   __index = TokenC,
   __tostring = function(self: TokenC): string
      return string.format("Token(kind=%d, span=%d:%d:%d:+%d)", self.kind, self.file_id, self.line, self.col, self.stop - self.start)
   end,
})

return {
   new_lexer = new_lexer,
   next_token = next_token,
   lexeme = TokenC.lexeme,
   -- token_from_c = token_from_c,
   -- Token = Token,
   -- lex_all = lex_all,
   LexerState = LexerState,
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
   Token = TokenC,
}
