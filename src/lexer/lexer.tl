local ffi = require("ffi")
local bit = require("bit")
local Span = require("util.span")
local band = bit.band
local bor = bit.bor

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

local record TokenC is ffi.CData
   where ffi.istype("tl_token_fast", self)
   start: integer
   stop: integer
   line: integer
   col: integer
   kind: integer
   flags: integer
end

local record Token
   kind: TokenKind
   lexeme: string
   span: Span
   has_newline: boolean
end

local record Uint8Array is {integer}, ffi.CData
end

local type Uint8Ptr = ffi.Pointer<integer>

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
local PROP_SPACE = 1
local PROP_DIGIT = 2
local PROP_ALPHA = 4
local PROP_IDENT = 8 -- ALPHA | DIGIT | _
local PROP_HEX = 16

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
         
         local s = ffi.string(ptr + start_pos, pos - start_pos)
         kind = keywords[s] and K_KEYWORD or K_IDENTIFIER
      
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
   if kind == K_EOF then
      tok.kind = K_EOF
      tok.start = pos
      tok.stop = pos
      tok.line = line
      tok.col = col
      tok.flags = 0
      return tok
   end

   tok.kind = kind
   tok.start = start_pos
   tok.stop = pos
   tok.line = line
   tok.col = start_col
   tok.flags = newline_flag
   return tok
end

local function lexeme(state: LexerState, tok: TokenC): string
   return ffi.string(state.src_ptr + tok.start, tok.stop - tok.start)
end

local function token_from_c(state: LexerState, tc: TokenC): Token
   local lx = lexeme(state, tc)
   local span = Span.new(state.file_id, tc.start + 1, tc.stop + 1, tc.line, tc.col)
   return {
      kind = tc.kind,
      lexeme = lx,
      span = span,
      has_newline = band(tc.flags, TOKEN_FLAG_NEWLINE) ~= 0,
   }
end

local function lex_all(source: string, file_id: integer): {Token}
   local lex = new_lexer(source, file_id)
   local out: {Token} = {}
   while true do
      local tc = next_token(lex)
      out[#out + 1] = token_from_c(lex, tc)
      if tc.kind == K_EOF then
         break
      end
   end
   return out
end

return {
   new_lexer = new_lexer,
   next_token = next_token,
   lexeme = lexeme,
   token_from_c = token_from_c,
   Token = Token,
   lex_all = lex_all,
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
   TokenC = TokenC,
}
