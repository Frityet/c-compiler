local ffi = require("ffi")
local bit = require("bit")
local Span = require("util.span")
local token_mod = require("lexer.token")
local TokenRecord = token_mod.Token
local type Token = token_mod.Token

local band = bit.band
local bor = bit.bor

ffi.cdef[[
typedef struct {
  uint32_t start;      /* 0-based */
  uint32_t stop;       /* exclusive */
  uint32_t line;       /* 1-based */
  uint32_t col;        /* 1-based */
  uint8_t kind;        /* TokenKindId */
  uint8_t flags;       /* TokenFlags */
} tl_token_ffi;
]]

local record TokenC is ffi.CData where ffi.istype("struct tl_token_ffi", self)
   start: integer
   stop: integer
   line: integer
   col: integer
   kind: integer
   flags: integer
end

local record U8 is ffi.CData where ffi.istype("uint8_t", self) end

local type TokenArray = ffi.Array<TokenC>
local type Uint8Array = ffi.Array<U8>
local type Uint8Ptr = ffi.Pointer<U8>

local TOKEN_FLAG_NEWLINE = 1 -- token follows a newline (whitespace/comment had newline)

local TokenCType = ffi.typeof("tl_token_ffi")
local TokenArrayType = ffi.typeof("tl_token_ffi[?]")

local K_IDENTIFIER = 1
local K_NUMBER = 2
local K_STRING = 3
local K_CHAR = 4
local K_KEYWORD = 5
local K_PUNCT = 6
local K_EOF = 7

local kind_to_string = {
   [K_IDENTIFIER] = "identifier",
   [K_NUMBER] = "number",
   [K_STRING] = "string",
   [K_CHAR] = "char",
   [K_KEYWORD] = "keyword",
   [K_PUNCT] = "punctuator",
   [K_EOF] = "eof",
}

-- Character properties
local PROP_SPACE = 1
local PROP_DIGIT = 2
local PROP_ALPHA = 4
local PROP_IDENT = 8
local PROP_HEX = 16

local char_props: Uint8Array = ffi.new("uint8_t[256]")
local punct_max_len: Uint8Array = ffi.new("uint8_t[256]")

local keywords: {string:boolean} = {
   ["auto"] = true, ["break"] = true, ["case"] = true, ["char"] = true, ["const"] = true,
   ["continue"] = true, ["default"] = true, ["do"] = true, ["double"] = true, ["else"] = true,
   ["enum"] = true, ["extern"] = true, ["float"] = true, ["for"] = true, ["goto"] = true,
   ["if"] = true, ["inline"] = true, ["int"] = true, ["long"] = true, ["register"] = true,
   ["restrict"] = true, ["return"] = true, ["short"] = true, ["signed"] = true, ["sizeof"] = true,
   ["static"] = true, ["struct"] = true, ["switch"] = true, ["typedef"] = true, ["union"] = true,
   ["unsigned"] = true, ["void"] = true, ["volatile"] = true, ["while"] = true, ["_Bool"] = true,
   ["_Complex"] = true, ["_Imaginary"] = true,
}

local punctuators: {string:boolean} = {
   ["{"] = true, ["}"] = true, ["("] = true, [")"] = true, ["["] = true, ["]"] = true,
   [";"] = true, [","] = true, ["."] = true, ["->"] = true, ["++"] = true, ["--"] = true,
   ["&"] = true, ["*"] = true, ["+"] = true, ["-"] = true, ["~"] = true, ["!"] = true,
   ["/"] = true, ["%"] = true, ["<<"] = true, [">>"] = true, ["<"] = true, [">"] = true,
   ["<="] = true, [">="] = true, ["=="] = true, ["!="] = true, ["^"] = true, ["|"] = true,
   ["&&"] = true, ["||"] = true, ["?"] = true, [":"] = true, ["#"] = true, ["##"] = true, ["="] = true, ["+="] = true,
   ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true, ["&="] = true, ["|="] = true,
   ["^="] = true, ["<<="] = true, [">>="] = true, ["..."] = true,
}

-- local macroexp bval(u: U8): integer
--    return math.tointeger(tonumber(u) or 0) or 0
-- end

for i = 0, 255 do
   local c = string.char(i)
   local p = 0
   if c:match("%s") then p = bor(p, PROP_SPACE) end
   if c:match("%d") then p = bor(p, PROP_DIGIT) end
   if c:match("[%a_]") then p = bor(p, PROP_ALPHA) end
   if c:match("[%w_]") then p = bor(p, PROP_IDENT) end
   if c:match("[%da-fA-F]") then p = bor(p, PROP_HEX) end
   char_props[i] = ffi.cast("uint8_t", p) as U8
end

for k, _ in pairs(punctuators) do
   local b = string.byte(k, 1)
   local l = #k
   local current = tonumber(punct_max_len[b]) or 0
   if l > current then
      punct_max_len[b] = ffi.cast("uint8_t", l) as U8
   end
end

local empty_tbl = {} -- reused for leading/trailing

local record LexBuffer
   data: TokenArray
   count: integer
   cap: integer
   src: string
   src_ptr: Uint8Ptr
   file_id: integer
   lexeme_cache: {string}
end

local function ensure(buf: LexBuffer, needed: integer)
   if needed <= buf.cap then
      return
   end
   local new_cap = buf.cap * 2
   if new_cap < needed then
      new_cap = needed
   end
   local new_data: TokenArray = ffi.new(TokenArrayType, new_cap)
   ffi.copy(new_data as ffi.Pointer<TokenC>, buf.data as ffi.Pointer<TokenC>, ffi.sizeof(TokenCType) * (buf.count + 1))
   buf.data = new_data
   buf.cap = new_cap
end

local function push(buf: LexBuffer, kind: integer, start_pos: integer, stop_pos: integer, line: integer, col: integer, flags: integer)
   local idx = buf.count + 1
   ensure(buf, idx + 1)
   local t = buf.data[idx]
   t.start = start_pos
   t.stop = stop_pos
   t.line = line
   t.col = col
   t.kind = kind
   t.flags = flags
   buf.count = idx
end

local function lexeme(buf: LexBuffer, index: integer): string
   local cached = buf.lexeme_cache[index]
   if cached then
      return cached
   end
   local t = buf.data[index]
   local s = ffi.string(buf.src_ptr + t.start, t.stop - t.start)
   buf.lexeme_cache[index] = s
   return s
end

local function lex(source: string, file_id: integer): LexBuffer
   local len = #source
   local ptr: Uint8Ptr = ffi.cast("const uint8_t*", source)
   local buf: LexBuffer = {
      data = ffi.new(TokenArrayType, 1024),
      count = 0,
      cap = 1024,
      src = source,
      src_ptr = ptr,
      file_id = file_id,
      lexeme_cache = {},
   }

   local pos = 0
   local line = 1
   local col = 1
   local newline_flag = false

   local function skip_whitespace(): boolean
      local saw_nl = false
      while pos < len do
         local c = ptr[pos]
         if band(tonumber(char_props[tonumber(c) as integer]) as integer, PROP_SPACE) ~= 0 then
            if tonumber(c) == 10 then
               pos = pos + 1
               line = line + 1
               col = 1
               saw_nl = true
            else
               pos = pos + 1
               col = col + 1
            end
            elseif tonumber(c) == 47 then -- / comment
               if pos + 1 < len then
                  local next_c = ptr[pos + 1]
                  if tonumber(next_c) == 47 then
                  pos = pos + 2
                  col = col + 2
                  while pos < len do
                     local cc = ptr[pos]
                     if tonumber(cc) == 10 then
                        break
                     end
                     pos = pos + 1
                     col = col + 1
                  end
                  elseif tonumber(next_c) == 42 then
                     pos = pos + 2
                     col = col + 2
                     while pos < len do
                        local cc = ptr[pos]
                        if tonumber(cc) == 42 and pos + 1 < len and tonumber(ptr[pos + 1]) == 47 then
                       pos = pos + 2
                       col = col + 2
                       break
                     end
                     if tonumber(cc) == 10 then
                        line = line + 1
                        col = 1
                        saw_nl = true
                     else
                        col = col + 1
                     end
                     pos = pos + 1
                  end
               else
                  return saw_nl
               end
            else
               return saw_nl
            end
         else
            break
         end
      end
      return saw_nl
   end

   local function read_identifier_or_keyword(nl: boolean)
      local start_pos = pos
      local start_col = col
      pos = pos + 1
      col = col + 1
      while pos < len do
         local c = ptr[pos]
         if band(tonumber(char_props[tonumber(c) as integer]) as integer, PROP_IDENT) ~= 0 then
            pos = pos + 1
            col = col + 1
         else
            break
         end
      end
      local k = K_IDENTIFIER
      local lx = ffi.string(ptr + start_pos, pos - start_pos)
      if keywords[lx] then
         k = K_KEYWORD
      end
      push(buf, k, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
      buf.lexeme_cache[buf.count] = lx
   end

   local function read_number(nl: boolean)
      local start_pos = pos
      local start_col = col
      repeat
         local c = ptr[pos]
         if band(tonumber(char_props[tonumber(c) as integer]) as integer, PROP_DIGIT) ~= 0 or tonumber(c) == 46 or tonumber(c) == 120 or tonumber(c) == 88 or tonumber(c) == 112 or tonumber(c) == 80 or tonumber(c) == 101 or tonumber(c) == 69 or tonumber(c) == 117 or tonumber(c) == 85 or tonumber(c) == 108 or tonumber(c) == 76 then
            pos = pos + 1
            col = col + 1
         else
            break
         end
      until pos >= len
      push(buf, K_NUMBER, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
   end

   local function read_string_like(nl: boolean, quote: integer, kind: integer)
      local start_pos = pos
      local start_col = col
      pos = pos + 1
      col = col + 1
      while pos < len do
         local c = ptr[pos]
         if tonumber(c) == 92 then
            if pos + 1 < len then
               pos = pos + 2
               col = col + 2
            else
               pos = pos + 1
               col = col + 1
               break
            end
         elseif tonumber(c) == quote then
            pos = pos + 1
            col = col + 1
            break
         elseif tonumber(c) == 10 then
            line = line + 1
            col = 1
            pos = pos + 1
         else
            pos = pos + 1
            col = col + 1
         end
      end
      push(buf, kind, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
   end

   local function match_punctuator(nl: boolean)
      local start_pos = pos
      local start_col = col
      local c = ptr[pos]
      local max_len = punct_max_len[tonumber(c) as integer]
      if tonumber(max_len) >= 3 and pos + 2 < len then
         local s = ffi.string(ptr + pos, 3)
         if punctuators[s] then
            pos = pos + 3
            col = col + 3
            push(buf, K_PUNCT, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
            buf.lexeme_cache[buf.count] = s
            return
         end
      end
      if tonumber(max_len) >= 2 and pos + 1 < len then
         local s = ffi.string(ptr + pos, 2)
         if punctuators[s] then
            pos = pos + 2
            col = col + 2
            push(buf, K_PUNCT, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
            buf.lexeme_cache[buf.count] = s
            return
         end
      end
      local s1 = string.char(tonumber(c) as integer)
      pos = pos + 1
      col = col + 1
      push(buf, K_PUNCT, start_pos, pos, line, start_col, nl and TOKEN_FLAG_NEWLINE or 0)
      buf.lexeme_cache[buf.count] = s1
   end

   while pos < len do
      newline_flag = skip_whitespace()
      if pos >= len then break end
      local c = ptr[pos]
      if tonumber(c) == 76 then
         local next_c = (pos + 1 < len) and (tonumber(ptr[pos + 1]) as integer) or 0
         if tonumber(next_c) == 34 or tonumber(next_c) == 39 then
            local start = pos
            pos = pos + 1
            col = col + 1
            read_string_like(newline_flag, tonumber(next_c) as integer, tonumber(next_c) == 39 and K_CHAR or K_STRING)
            buf.lexeme_cache[buf.count] = ffi.string(ptr + start, pos - start)
         else
            read_identifier_or_keyword(newline_flag)
         end
      elseif band(tonumber(char_props[tonumber(c) as integer]) as integer, PROP_ALPHA) ~= 0 then
         read_identifier_or_keyword(newline_flag)
      elseif band(tonumber(char_props[tonumber(c) as integer]) as integer, PROP_DIGIT) ~= 0 then
         read_number(newline_flag)
      elseif tonumber(c) == 39 then
         read_string_like(newline_flag, 39, K_CHAR)
      elseif tonumber(c) == 34 then
         read_string_like(newline_flag, 34, K_STRING)
      else
         match_punctuator(newline_flag)
      end
      newline_flag = false
   end

   push(buf, K_EOF, pos, pos, line, col, newline_flag and TOKEN_FLAG_NEWLINE or 0)
   buf.lexeme_cache[buf.count] = ""
   return buf
end

local function token_kind_name(kind_id: integer): string
   return kind_to_string[kind_id] or "unknown"
end

local function to_token(buf: LexBuffer, idx: integer): Token
   local t = buf.data[idx]
   local kind = token_kind_name(t.kind) as token_mod.TokenKind
   local lx = lexeme(buf, idx)
   local span = Span.new(buf.file_id, t.start + 1, t.stop + 1, t.line, t.col)
   return TokenRecord.new(kind, lx, span, empty_tbl, empty_tbl, band(t.flags, TOKEN_FLAG_NEWLINE) ~= 0)
end

local function to_token_array(buf: LexBuffer): {Token}
   local out: {Token} = {}
   for i = 1, buf.count do
      out[i] = to_token(buf, i)
   end
   return out
end

return {
   K_IDENTIFIER = K_IDENTIFIER,
   K_NUMBER = K_NUMBER,
   K_STRING = K_STRING,
   K_CHAR = K_CHAR,
   K_KEYWORD = K_KEYWORD,
   K_PUNCT = K_PUNCT,
   K_EOF = K_EOF,
   TOKEN_FLAG_NEWLINE = TOKEN_FLAG_NEWLINE,
   lex = lex,
   lexeme = lexeme,
   to_token = to_token,
   to_token_array = to_token_array,
   token_kind_name = token_kind_name,
   LexBuffer = LexBuffer,
}
