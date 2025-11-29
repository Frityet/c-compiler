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
local K_KEYWORD_AUTO<const> = 5
local K_KEYWORD_BREAK<const> = 6
local K_KEYWORD_CASE<const> = 7
local K_KEYWORD_CHAR<const> = 8
local K_KEYWORD_CONST<const> = 9
local K_KEYWORD_CONTINUE<const> = 10
local K_KEYWORD_DEFAULT<const> = 11
local K_KEYWORD_DO<const> = 12
local K_KEYWORD_DOUBLE<const> = 13
local K_KEYWORD_ELSE<const> = 14
local K_KEYWORD_ENUM<const> = 15
local K_KEYWORD_EXTERN<const> = 16
local K_KEYWORD_FLOAT<const> = 17
local K_KEYWORD_FOR<const> = 18
local K_KEYWORD_GOTO<const> = 19
local K_KEYWORD_IF<const> = 20
local K_KEYWORD_INLINE<const> = 21
local K_KEYWORD_INT<const> = 22
local K_KEYWORD_LONG<const> = 23
local K_KEYWORD_REGISTER<const> = 24
local K_KEYWORD_RESTRICT<const> = 25
local K_KEYWORD_RETURN<const> = 26
local K_KEYWORD_SHORT<const> = 27
local K_KEYWORD_SIGNED<const> = 28
local K_KEYWORD_SIZEOF<const> = 29
local K_KEYWORD_STATIC<const> = 30
local K_KEYWORD_STRUCT<const> = 31
local K_KEYWORD_SWITCH<const> = 32
local K_KEYWORD_TYPEDEF<const> = 33
local K_KEYWORD_UNION<const> = 34
local K_KEYWORD_UNSIGNED<const> = 35
local K_KEYWORD_VOID<const> = 36
local K_KEYWORD_VOLATILE<const> = 37
local K_KEYWORD_WHILE<const> = 38
local K_KEYWORD__BOOL<const> = 39
local K_KEYWORD__COMPLEX<const> = 40
local K_KEYWORD__IMAGINARY<const> = 41
local K_KEYWORD__ALIGNAS<const> = 42
local K_KEYWORD__ALIGNOF<const> = 43
local K_KEYWORD__ATOMIC<const> = 44
local K_KEYWORD__GENERIC<const> = 45
local K_KEYWORD__NORETURN<const> = 46
local K_KEYWORD__STATIC_ASSERT<const> = 47
local K_KEYWORD__THREAD_LOCAL<const> = 48
local KEYWORD_MIN<const> = K_KEYWORD_AUTO
local KEYWORD_MAX<const> = K_KEYWORD__THREAD_LOCAL

local K_PUNCT_PLUS<const> = 49
local K_PUNCT_MINUS<const> = 50
local K_PUNCT_STAR<const> = 51
local K_PUNCT_SLASH<const> = 52
local K_PUNCT_PERCENT<const> = 53
local K_PUNCT_CARET<const> = 54
local K_PUNCT_AMP<const> = 55
local K_PUNCT_BAR<const> = 56
local K_PUNCT_TILDE<const> = 57
local K_PUNCT_BANG<const> = 58
local K_PUNCT_EQ<const> = 59
local K_PUNCT_LT<const> = 60
local K_PUNCT_GT<const> = 61
local K_PUNCT_QUESTION<const> = 62
local K_PUNCT_PLUS_PLUS<const> = 63
local K_PUNCT_MINUS_MINUS<const> = 64
local K_PUNCT_PLUS_EQ<const> = 65
local K_PUNCT_MINUS_EQ<const> = 66
local K_PUNCT_STAR_EQ<const> = 67
local K_PUNCT_SLASH_EQ<const> = 68
local K_PUNCT_PERCENT_EQ<const> = 69
local K_PUNCT_CARET_EQ<const> = 70
local K_PUNCT_AMP_EQ<const> = 71
local K_PUNCT_BAR_EQ<const> = 72
local K_PUNCT_LT_LT_EQ<const> = 73
local K_PUNCT_GT_GT_EQ<const> = 74
local K_PUNCT_EQ_EQ<const> = 75
local K_PUNCT_BANG_EQ<const> = 76
local K_PUNCT_LT_EQ<const> = 77
local K_PUNCT_GT_EQ<const> = 78
local K_PUNCT_AMP_AMP<const> = 79
local K_PUNCT_BAR_BAR<const> = 80
local K_PUNCT_LT_LT<const> = 81
local K_PUNCT_GT_GT<const> = 82
local K_PUNCT_ARROW<const> = 83
local K_PUNCT_DOT<const> = 84
local K_PUNCT_COMMA<const> = 85
local K_PUNCT_SEMICOLON<const> = 86
local K_PUNCT_COLON<const> = 87
local K_PUNCT_LPAREN<const> = 88
local K_PUNCT_RPAREN<const> = 89
local K_PUNCT_LBRACKET<const> = 90
local K_PUNCT_RBRACKET<const> = 91
local K_PUNCT_LBRACE<const> = 92
local K_PUNCT_RBRACE<const> = 93
local K_PUNCT_ELLIPSIS<const> = 94
local K_PUNCT_HASH_HASH<const> = 95
local K_PUNCT_HASH<const> = 96
local PUNCT_MIN<const> = K_PUNCT_PLUS
local PUNCT_MAX<const> = K_PUNCT_HASH

local K_EOF<const> = 97
local K_COMMENT<const> = 98
local K_WHITESPACE<const> = 99

-- Sentinels for category matching (not emitted as token kinds)
local K_KEYWORD<const> = -1
local K_PUNCT<const> = -2

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

ffi.cdef [[
struct tl_lexer_state {
    // const uint8_t *src;
    const uint8_t *src_ptr;
    uint32_t len;
    uint32_t pos;
    uint32_t line;
    uint32_t col;
    uint32_t file_id;
    uint8_t newline_flag;
   tl_token_fast current_token;
};
]]

local record LexerState is ffi.CData where ffi.istype("struct tl_lexer_state", self)
   src_ptr: Uint8Ptr
   len: integer
   pos: integer
   line: integer
   col: integer
   file_id: integer
   newline_flag: integer
   -- current_token: ffi.Pointer<TokenC>
   current_token: TokenC
end

-- Keep source buffers alive for each lexer state; weak keys so buffers can be GC'd with the state
local state_buffers = setmetatable({}, { __mode = "k" })

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
local type KeywordKindMap = {string: TokenKind}
local type PunctKindMap = {string: TokenKind}

local KEYWORDS<const>: KeywordKindMap = {
   auto = K_KEYWORD_AUTO,
   ["break"] = K_KEYWORD_BREAK,
   ["case"] = K_KEYWORD_CASE,
   ["char"] = K_KEYWORD_CHAR,
   ["const"] = K_KEYWORD_CONST,
   ["continue"] = K_KEYWORD_CONTINUE,
   ["default"] = K_KEYWORD_DEFAULT,
   ["do"] = K_KEYWORD_DO,
   ["double"] = K_KEYWORD_DOUBLE,
   ["else"] = K_KEYWORD_ELSE,
   ["enum"] = K_KEYWORD_ENUM,
   ["extern"] = K_KEYWORD_EXTERN,
   ["float"] = K_KEYWORD_FLOAT,
   ["for"] = K_KEYWORD_FOR,
   ["goto"] = K_KEYWORD_GOTO,
   ["if"] = K_KEYWORD_IF,
   ["inline"] = K_KEYWORD_INLINE,
   ["int"] = K_KEYWORD_INT,
   ["long"] = K_KEYWORD_LONG,
   ["register"] = K_KEYWORD_REGISTER,
   ["restrict"] = K_KEYWORD_RESTRICT,
   ["return"] = K_KEYWORD_RETURN,
   ["short"] = K_KEYWORD_SHORT,
   ["signed"] = K_KEYWORD_SIGNED,
   ["sizeof"] = K_KEYWORD_SIZEOF,
   ["static"] = K_KEYWORD_STATIC,
   ["struct"] = K_KEYWORD_STRUCT,
   ["switch"] = K_KEYWORD_SWITCH,
   ["typedef"] = K_KEYWORD_TYPEDEF,
   ["union"] = K_KEYWORD_UNION,
   ["unsigned"] = K_KEYWORD_UNSIGNED,
   ["void"] = K_KEYWORD_VOID,
   ["volatile"] = K_KEYWORD_VOLATILE,
   ["while"] = K_KEYWORD_WHILE,
   ["_Bool"] = K_KEYWORD__BOOL,
   ["_Complex"] = K_KEYWORD__COMPLEX,
   ["_Imaginary"] = K_KEYWORD__IMAGINARY,
   ["_Alignas"] = K_KEYWORD__ALIGNAS,
   ["_Alignof"] = K_KEYWORD__ALIGNOF,
   ["_Atomic"] = K_KEYWORD__ATOMIC,
   ["_Generic"] = K_KEYWORD__GENERIC,
   ["_Noreturn"] = K_KEYWORD__NORETURN,
   ["_Static_assert"] = K_KEYWORD__STATIC_ASSERT,
   ["_Thread_local"] = K_KEYWORD__THREAD_LOCAL,
}

local PUNCT<const>: PunctKindMap = {
   ["+"] = K_PUNCT_PLUS,
   ["-"] = K_PUNCT_MINUS,
   ["*"] = K_PUNCT_STAR,
   ["/"] = K_PUNCT_SLASH,
   ["%"] = K_PUNCT_PERCENT,
   ["^"] = K_PUNCT_CARET,
   ["&"] = K_PUNCT_AMP,
   ["|"] = K_PUNCT_BAR,
   ["~"] = K_PUNCT_TILDE,
   ["!"] = K_PUNCT_BANG,
   ["="] = K_PUNCT_EQ,
   ["<"] = K_PUNCT_LT,
   [">"] = K_PUNCT_GT,
   ["?"] = K_PUNCT_QUESTION,
   ["++"] = K_PUNCT_PLUS_PLUS,
   ["--"] = K_PUNCT_MINUS_MINUS,
   ["+="] = K_PUNCT_PLUS_EQ,
   ["-="] = K_PUNCT_MINUS_EQ,
   ["*="] = K_PUNCT_STAR_EQ,
   ["/="] = K_PUNCT_SLASH_EQ,
   ["%="] = K_PUNCT_PERCENT_EQ,
   ["^="] = K_PUNCT_CARET_EQ,
   ["&="] = K_PUNCT_AMP_EQ,
   ["|="] = K_PUNCT_BAR_EQ,
   ["<<="] = K_PUNCT_LT_LT_EQ,
   [">>="] = K_PUNCT_GT_GT_EQ,
   ["=="] = K_PUNCT_EQ_EQ,
   ["!="] = K_PUNCT_BANG_EQ,
   ["<="] = K_PUNCT_LT_EQ,
   [">="] = K_PUNCT_GT_EQ,
   ["&&"] = K_PUNCT_AMP_AMP,
   ["||"] = K_PUNCT_BAR_BAR,
   ["<<"] = K_PUNCT_LT_LT,
   [">>"] = K_PUNCT_GT_GT,
   ["->"] = K_PUNCT_ARROW,
   ["."] = K_PUNCT_DOT,
   [","] = K_PUNCT_COMMA,
   [";"] = K_PUNCT_SEMICOLON,
   [":"] = K_PUNCT_COLON,
   ["("] = K_PUNCT_LPAREN,
   [")"] = K_PUNCT_RPAREN,
   ["["] = K_PUNCT_LBRACKET,
   ["]"] = K_PUNCT_RBRACKET,
   ["{"] = K_PUNCT_LBRACE,
   ["}"] = K_PUNCT_RBRACE,
   ["..."] = K_PUNCT_ELLIPSIS,
   ["##"] = K_PUNCT_HASH_HASH,
   ["#"] = K_PUNCT_HASH,
}

local kind_to_lexeme: {TokenKind: string} = {}
for lexeme, kind in pairs(KEYWORDS) do
   kind_to_lexeme[kind] = lexeme
end
for lexeme, kind in pairs(PUNCT) do
   kind_to_lexeme[kind] = lexeme
   local first = string.byte(lexeme, 1)
   if #lexeme > punct_max_len_c[first] then
      punct_max_len_c[first] = #lexeme
   end
end

-- local keywords: {string:boolean} = {
--    ["auto"] = true, ["break"] = true, ["case"] = true, ["char"] = true,
--    ["const"] = true, ["continue"] = true, ["default"] = true, ["do"] = true,
--    ["double"] = true, ["else"] = true, ["enum"] = true, ["extern"] = true,
--    ["float"] = true, ["for"] = true, ["goto"] = true, ["if"] = true,
--    ["int"] = true, ["long"] = true, ["register"] = true, ["return"] = true,
--    ["short"] = true, ["signed"] = true, ["sizeof"] = true, ["static"] = true,
--    ["struct"] = true, ["switch"] = true, ["typedef"] = true, ["union"] = true,
--    ["unsigned"] = true, ["void"] = true, ["volatile"] = true, ["while"] = true,
--    ["_Bool"] = true, ["_Complex"] = true, ["_Imaginary"] = true, ["inline"] = true,
--    ["restrict"] = true, ["_Alignas"] = true, ["_Alignof"] = true, ["_Atomic"] = true,
--    ["_Generic"] = true, ["_Noreturn"] = true, ["_Static_assert"] = true, ["_Thread_local"] = true,
-- }

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

local macro is_kw!(s: Expression, kw: Expression): Expression
   expect(s, "variable")
   expect(kw, "string")

   local kwlen = #kw.conststr
   local n = block("integer")
   n.constnum = kwlen
   n.tk = tostring(kwlen)

   return `(C.memcmp as function(ffi.CData, ffi.String, integer))($s, $kw, $n) == 0`
end

local macro char!(x: Expression): Expression
   expect(x, "string")

   local n = block("integer")
   n.constnum = string.byte(x.conststr, 1)
   n.tk = tostring(n.constnum)
   return n
end

--x should be `<var> == <LIT>`
local macro expand_cmp!(x: Expression): Expression
   expect(x, "op_eq")
   expect(x[1], "variable")
   expect(x[2], "string")

   local var, str = x[1], x[2]
   local char = string.byte(str.conststr, 1)
   local char_node = block("integer")
   char_node.constnum = char
   char_node.tk = tostring(char)
   local i_blk = block("integer")
   i_blk.constnum = 0
   i_blk.tk = "0"
   local expr = `($var)[$i_blk] == $char_node`
   for i = 2, #x[2].conststr do
      i_blk.constnum = i-1
      i_blk.tk = tostring(i-1)

      char_node.constnum = string.byte(str.conststr, i)
      char_node.tk = tostring(char_node.constnum)

      expr = `$expr and ($var)[$i_blk] == $char_node`
   end
   return expr
end


local function is_keyword_kind(kind: TokenKind): boolean
   return kind >= KEYWORD_MIN and kind <= KEYWORD_MAX
end

local function is_punct_kind(kind: TokenKind): boolean
   return kind >= PUNCT_MIN and kind <= PUNCT_MAX
end

local function keyword_kind_from_lexeme(lexeme: string): TokenKind | nil
   return KEYWORDS[lexeme]
end

local function punct_kind_from_lexeme(lexeme: string): TokenKind | nil
   return PUNCT[lexeme]
end

local function kind_lexeme(kind: TokenKind): string | nil
   return kind_to_lexeme[kind]
end

local function keyword_kind(s: Uint8Ptr, len: integer): TokenKind | nil
   if len < 2 or len > 14 then
      return nil
   end

   local c0 = s[0]
   if c0 == char! '_' then
      if len == 5 then
         if expand_cmp!(s == '_Bool') then return K_KEYWORD__BOOL end
      elseif len == 7 then
         if is_kw!(s, "_Atomic") then return K_KEYWORD__ATOMIC end
      elseif len == 8 then
         if is_kw!(s, "_Complex") then return K_KEYWORD__COMPLEX end
         if is_kw!(s, "_Alignas") then return K_KEYWORD__ALIGNAS end
         if is_kw!(s, "_Alignof") then return K_KEYWORD__ALIGNOF end
         if is_kw!(s, "_Generic") then return K_KEYWORD__GENERIC end
      elseif len == 9 then
         if is_kw!(s, "_Noreturn") then return K_KEYWORD__NORETURN end
      elseif len == 10 then
         if is_kw!(s, "_Imaginary") then return K_KEYWORD__IMAGINARY end
      elseif len == 13 then
         if is_kw!(s, "_Thread_local") then return K_KEYWORD__THREAD_LOCAL end
      elseif len == 14 then
         if is_kw!(s, "_Static_assert") then return K_KEYWORD__STATIC_ASSERT end
      end
      return nil
   end

   if len == 2 then
      if expand_cmp!(s == 'do') then return K_KEYWORD_DO end
      if expand_cmp!(s == "if") then return K_KEYWORD_IF end
   elseif len == 3 then
      if expand_cmp!(s == "for") then return K_KEYWORD_FOR end
      if expand_cmp!(s == "int") then return K_KEYWORD_INT end
   elseif len == 4 then
      if c0 == char!'a' then
         if expand_cmp!(s == "auto") then return K_KEYWORD_AUTO end
      elseif c0 == char!'c' then
         if expand_cmp!(s == "case") then return K_KEYWORD_CASE end
         if expand_cmp!(s == "char") then return K_KEYWORD_CHAR end
      elseif c0 == char!'e' then
         if expand_cmp!(s == "else") then return K_KEYWORD_ELSE end
         if expand_cmp!(s == "enum") then return K_KEYWORD_ENUM end
      elseif c0 == char!'g' then
         if expand_cmp!(s == "goto") then return K_KEYWORD_GOTO end
      elseif c0 == char!'l' then
         if expand_cmp!(s == "long") then return K_KEYWORD_LONG end
      elseif c0 == char!'v' then
         if expand_cmp!(s == "void") then return K_KEYWORD_VOID end
      end
   elseif len == 5 then
      if expand_cmp!(s == "break") then return K_KEYWORD_BREAK end
      if expand_cmp!(s == "const") then return K_KEYWORD_CONST end
      if expand_cmp!(s == "float") then return K_KEYWORD_FLOAT end
      if expand_cmp!(s == "short") then return K_KEYWORD_SHORT end
      if expand_cmp!(s == "while") then return K_KEYWORD_WHILE end
      if expand_cmp!(s == "union") then return K_KEYWORD_UNION end
   elseif len == 6 then
      if c0 == char!'d' then
         if is_kw!(s, "double") then return K_KEYWORD_DOUBLE end
      elseif c0 == char!'e' then
         if is_kw!(s, "extern") then return K_KEYWORD_EXTERN end
      elseif c0 == char!'i' then
         if is_kw!(s, "inline") then return K_KEYWORD_INLINE end
      elseif c0 == char!'r' then
         if is_kw!(s, "return") then return K_KEYWORD_RETURN end
         if is_kw!(s, "signed") then return K_KEYWORD_SIGNED end
      elseif c0 == char!'s' then
         if is_kw!(s, "sizeof") then return K_KEYWORD_SIZEOF end
         if is_kw!(s, "static") then return K_KEYWORD_STATIC end
         if is_kw!(s, "struct") then return K_KEYWORD_STRUCT end
         if is_kw!(s, "switch") then return K_KEYWORD_SWITCH end
      end
   elseif len == 7 then
      if c0 == char!'d' then
         if is_kw!(s, "default") then return K_KEYWORD_DEFAULT end
      elseif c0 == char!'t' then
         if is_kw!(s, "typedef") then return K_KEYWORD_TYPEDEF end
      end
   elseif len == 8 then
      if c0 == char!'c' then
         if is_kw!(s, "continue") then return K_KEYWORD_CONTINUE end
      elseif c0 == char!'r' then
         if is_kw!(s, "register") then return K_KEYWORD_REGISTER end
         if is_kw!(s, "restrict") then return K_KEYWORD_RESTRICT end
      elseif c0 == char!'u' then
         if is_kw!(s, "unsigned") then return K_KEYWORD_UNSIGNED end
      elseif c0 == char!'v' then
         if is_kw!(s, "volatile") then return K_KEYWORD_VOLATILE end
      end
   end

   return nil
end

local function read_punct(ptr: Uint8Ptr, pos: integer, len: integer): (TokenKind, integer)
   local remaining = len - pos
   local c = ptr[pos]
   if c == char!'+' then
      if remaining > 1 then
         local c2 = ptr[pos + 1]
         if c2 == char!'+' then return K_PUNCT_PLUS_PLUS, 2 end
         if c2 == char!'=' then return K_PUNCT_PLUS_EQ, 2 end
      end
      return K_PUNCT_PLUS, 1
   elseif c == char!'-' then
      if remaining > 1 then
         local c2 = ptr[pos + 1]
         if c2 == char!'-' then return K_PUNCT_MINUS_MINUS, 2 end
         if c2 == char!'=' then return K_PUNCT_MINUS_EQ, 2 end
         if c2 == char!'>' then return K_PUNCT_ARROW, 2 end
      end
      return K_PUNCT_MINUS, 1
   elseif c == char!'*' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_STAR_EQ, 2
      end
      return K_PUNCT_STAR, 1
   elseif c == char!'/' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_SLASH_EQ, 2
      end
      return K_PUNCT_SLASH, 1
   elseif c == char!'%' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_PERCENT_EQ, 2
      end
      return K_PUNCT_PERCENT, 1
   elseif c == char!'^' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_CARET_EQ, 2
      end
      return K_PUNCT_CARET, 1
   elseif c == char!'&' then
      if remaining > 1 then
         local c2 = ptr[pos + 1]
         if c2 == char!'&' then return K_PUNCT_AMP_AMP, 2 end
         if c2 == char!'=' then return K_PUNCT_AMP_EQ, 2 end
      end
      return K_PUNCT_AMP, 1
   elseif c == char!'|' then
      if remaining > 1 then
         local c2 = ptr[pos + 1]
         if c2 == char!'|' then return K_PUNCT_BAR_BAR, 2 end
         if c2 == char!'=' then return K_PUNCT_BAR_EQ, 2 end
      end
      return K_PUNCT_BAR, 1
   elseif c == char!'~' then
      return K_PUNCT_TILDE, 1
   elseif c == char!'!' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_BANG_EQ, 2
      end
      return K_PUNCT_BANG, 1
   elseif c == char!'=' then
      if remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_EQ_EQ, 2
      end
      return K_PUNCT_EQ, 1
   elseif c == char!'<' then
      if remaining > 2 and ptr[pos + 1] == char!'<' and ptr[pos + 2] == char!'=' then
         return K_PUNCT_LT_LT_EQ, 3
      elseif remaining > 1 and ptr[pos + 1] == char!'<' then
         return K_PUNCT_LT_LT, 2
      elseif remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_LT_EQ, 2
      end
      return K_PUNCT_LT, 1
   elseif c == char!'>' then
      if remaining > 2 and ptr[pos + 1] == char!'>' and ptr[pos + 2] == char!'=' then
         return K_PUNCT_GT_GT_EQ, 3
      elseif remaining > 1 and ptr[pos + 1] == char!'>' then
         return K_PUNCT_GT_GT, 2
      elseif remaining > 1 and ptr[pos + 1] == char!'=' then
         return K_PUNCT_GT_EQ, 2
      end
      return K_PUNCT_GT, 1
   elseif c == char!'?' then
      return K_PUNCT_QUESTION, 1
   elseif c == char!'.' then
      if remaining > 2 and ptr[pos + 1] == char!'.' and ptr[pos + 2] == char!'.' then
         return K_PUNCT_ELLIPSIS, 3
      end
      return K_PUNCT_DOT, 1
   elseif c == char!',' then
      return K_PUNCT_COMMA, 1
   elseif c == char!';' then
      return K_PUNCT_SEMICOLON, 1
   elseif c == char!':' then
      return K_PUNCT_COLON, 1
   elseif c == char!'(' then
      return K_PUNCT_LPAREN, 1
   elseif c == char!')' then
      return K_PUNCT_RPAREN, 1
   elseif c == char!'[' then
      return K_PUNCT_LBRACKET, 1
   elseif c == char!']' then
      return K_PUNCT_RBRACKET, 1
   elseif c == char!'{' then
      return K_PUNCT_LBRACE, 1
   elseif c == char!'}' then
      return K_PUNCT_RBRACE, 1
   elseif c == char!'#' then
      if remaining > 1 and ptr[pos + 1] == char!'#' then
         return K_PUNCT_HASH_HASH, 2
      end
      return K_PUNCT_HASH, 1
   end

   return K_UNKNOWN, 1
end


local function new_lexer(source: string, file_id: integer): LexerState
   local len = #source
   local buf: ffi.CData = ffi.new("uint8_t[?]", len + 1, source)

   local state: LexerState = ffi.new("struct tl_lexer_state", {
      src_ptr = ffi.cast("const uint8_t*", buf),
      len = len,
      pos = 0,
      line = 1,
      col = 1,
      file_id = file_id,
      newline_flag = 0,
      current_token = ffi.new(TokenType)
   })
   state_buffers[state] = buf
   return state
end

local function next_token(state: LexerState): TokenC
   local ptr = state.src_ptr
   local len = state.len
   local pos = state.pos
   local line = state.line
   local col = state.col
   local newline_flag = state.newline_flag
   
   local cp = char_props_c
   
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

         local kw = keyword_kind(ptr + start_pos, pos - start_pos)
         if kw is nil then
            kind = K_IDENTIFIER
         else
            kind = kw
         end
      
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
            local pk, consumed = read_punct(ptr, pos, len)
            pos = pos + consumed
            col = col + consumed
            kind = pk
         end
         
      else
         local pk, consumed = read_punct(ptr, pos, len)
         pos = pos + consumed
         col = col + consumed
         kind = pk
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
      return ffi.new("tl_token_fast", tok)
   end

   tok.kind = kind
   tok.start = start_pos
   tok.stop = pos
   tok.line = line
   tok.col = start_col
   tok.flags = newline_flag

   -- local out: TokenC = ffi.new("tl_token_fast")
   -- ffi.copy(out, tok, ffi.sizeof("tl_token_fast"))
   -- return out
   return ffi.new("tl_token_fast", tok)
end

ffi.cdef [[
struct tl_string_view {
   const uint8_t *ptr;
   uint32_t len;
};
]]

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
   K_KEYWORD_AUTO = K_KEYWORD_AUTO,
   K_KEYWORD_BREAK = K_KEYWORD_BREAK,
   K_KEYWORD_CASE = K_KEYWORD_CASE,
   K_KEYWORD_CHAR = K_KEYWORD_CHAR,
   K_KEYWORD_CONST = K_KEYWORD_CONST,
   K_KEYWORD_CONTINUE = K_KEYWORD_CONTINUE,
   K_KEYWORD_DEFAULT = K_KEYWORD_DEFAULT,
   K_KEYWORD_DO = K_KEYWORD_DO,
   K_KEYWORD_DOUBLE = K_KEYWORD_DOUBLE,
   K_KEYWORD_ELSE = K_KEYWORD_ELSE,
   K_KEYWORD_ENUM = K_KEYWORD_ENUM,
   K_KEYWORD_EXTERN = K_KEYWORD_EXTERN,
   K_KEYWORD_FLOAT = K_KEYWORD_FLOAT,
   K_KEYWORD_FOR = K_KEYWORD_FOR,
   K_KEYWORD_GOTO = K_KEYWORD_GOTO,
   K_KEYWORD_IF = K_KEYWORD_IF,
   K_KEYWORD_INLINE = K_KEYWORD_INLINE,
   K_KEYWORD_INT = K_KEYWORD_INT,
   K_KEYWORD_LONG = K_KEYWORD_LONG,
   K_KEYWORD_REGISTER = K_KEYWORD_REGISTER,
   K_KEYWORD_RESTRICT = K_KEYWORD_RESTRICT,
   K_KEYWORD_RETURN = K_KEYWORD_RETURN,
   K_KEYWORD_SHORT = K_KEYWORD_SHORT,
   K_KEYWORD_SIGNED = K_KEYWORD_SIGNED,
   K_KEYWORD_SIZEOF = K_KEYWORD_SIZEOF,
   K_KEYWORD_STATIC = K_KEYWORD_STATIC,
   K_KEYWORD_STRUCT = K_KEYWORD_STRUCT,
   K_KEYWORD_SWITCH = K_KEYWORD_SWITCH,
   K_KEYWORD_TYPEDEF = K_KEYWORD_TYPEDEF,
   K_KEYWORD_UNION = K_KEYWORD_UNION,
   K_KEYWORD_UNSIGNED = K_KEYWORD_UNSIGNED,
   K_KEYWORD_VOID = K_KEYWORD_VOID,
   K_KEYWORD_VOLATILE = K_KEYWORD_VOLATILE,
   K_KEYWORD_WHILE = K_KEYWORD_WHILE,
   K_KEYWORD__BOOL = K_KEYWORD__BOOL,
   K_KEYWORD__COMPLEX = K_KEYWORD__COMPLEX,
   K_KEYWORD__IMAGINARY = K_KEYWORD__IMAGINARY,
   K_KEYWORD__ALIGNAS = K_KEYWORD__ALIGNAS,
   K_KEYWORD__ALIGNOF = K_KEYWORD__ALIGNOF,
   K_KEYWORD__ATOMIC = K_KEYWORD__ATOMIC,
   K_KEYWORD__GENERIC = K_KEYWORD__GENERIC,
   K_KEYWORD__NORETURN = K_KEYWORD__NORETURN,
   K_KEYWORD__STATIC_ASSERT = K_KEYWORD__STATIC_ASSERT,
   K_KEYWORD__THREAD_LOCAL = K_KEYWORD__THREAD_LOCAL,
   K_KEYWORD = K_KEYWORD,
   K_PUNCT_PLUS = K_PUNCT_PLUS,
   K_PUNCT_MINUS = K_PUNCT_MINUS,
   K_PUNCT_STAR = K_PUNCT_STAR,
   K_PUNCT_SLASH = K_PUNCT_SLASH,
   K_PUNCT_PERCENT = K_PUNCT_PERCENT,
   K_PUNCT_CARET = K_PUNCT_CARET,
   K_PUNCT_AMP = K_PUNCT_AMP,
   K_PUNCT_BAR = K_PUNCT_BAR,
   K_PUNCT_TILDE = K_PUNCT_TILDE,
   K_PUNCT_BANG = K_PUNCT_BANG,
   K_PUNCT_EQ = K_PUNCT_EQ,
   K_PUNCT_LT = K_PUNCT_LT,
   K_PUNCT_GT = K_PUNCT_GT,
   K_PUNCT_QUESTION = K_PUNCT_QUESTION,
   K_PUNCT_PLUS_PLUS = K_PUNCT_PLUS_PLUS,
   K_PUNCT_MINUS_MINUS = K_PUNCT_MINUS_MINUS,
   K_PUNCT_PLUS_EQ = K_PUNCT_PLUS_EQ,
   K_PUNCT_MINUS_EQ = K_PUNCT_MINUS_EQ,
   K_PUNCT_STAR_EQ = K_PUNCT_STAR_EQ,
   K_PUNCT_SLASH_EQ = K_PUNCT_SLASH_EQ,
   K_PUNCT_PERCENT_EQ = K_PUNCT_PERCENT_EQ,
   K_PUNCT_CARET_EQ = K_PUNCT_CARET_EQ,
   K_PUNCT_AMP_EQ = K_PUNCT_AMP_EQ,
   K_PUNCT_BAR_EQ = K_PUNCT_BAR_EQ,
   K_PUNCT_LT_LT_EQ = K_PUNCT_LT_LT_EQ,
   K_PUNCT_GT_GT_EQ = K_PUNCT_GT_GT_EQ,
   K_PUNCT_EQ_EQ = K_PUNCT_EQ_EQ,
   K_PUNCT_BANG_EQ = K_PUNCT_BANG_EQ,
   K_PUNCT_LT_EQ = K_PUNCT_LT_EQ,
   K_PUNCT_GT_EQ = K_PUNCT_GT_EQ,
   K_PUNCT_AMP_AMP = K_PUNCT_AMP_AMP,
   K_PUNCT_BAR_BAR = K_PUNCT_BAR_BAR,
   K_PUNCT_LT_LT = K_PUNCT_LT_LT,
   K_PUNCT_GT_GT = K_PUNCT_GT_GT,
   K_PUNCT_ARROW = K_PUNCT_ARROW,
   K_PUNCT_DOT = K_PUNCT_DOT,
   K_PUNCT_COMMA = K_PUNCT_COMMA,
   K_PUNCT_SEMICOLON = K_PUNCT_SEMICOLON,
   K_PUNCT_COLON = K_PUNCT_COLON,
   K_PUNCT_LPAREN = K_PUNCT_LPAREN,
   K_PUNCT_RPAREN = K_PUNCT_RPAREN,
   K_PUNCT_LBRACKET = K_PUNCT_LBRACKET,
   K_PUNCT_RBRACKET = K_PUNCT_RBRACKET,
   K_PUNCT_LBRACE = K_PUNCT_LBRACE,
   K_PUNCT_RBRACE = K_PUNCT_RBRACE,
   K_PUNCT_ELLIPSIS = K_PUNCT_ELLIPSIS,
   K_PUNCT_HASH_HASH = K_PUNCT_HASH_HASH,
   K_PUNCT_HASH = K_PUNCT_HASH,
   K_PUNCT = K_PUNCT,
   K_EOF = K_EOF,
   K_COMMENT = K_COMMENT,
   K_WHITESPACE = K_WHITESPACE,
   KEYWORDS = KEYWORDS,
   PUNCT = PUNCT,
   is_keyword_kind = is_keyword_kind,
   is_punct_kind = is_punct_kind,
   keyword_kind_from_lexeme = keyword_kind_from_lexeme,
   punct_kind_from_lexeme = punct_kind_from_lexeme,
   kind_lexeme = kind_lexeme,
   TOKEN_FLAG_NEWLINE = TOKEN_FLAG_NEWLINE,
   TOKEN_FLAG_LEADING_SPACE = TOKEN_FLAG_LEADING_SPACE,
   Token = TokenC,
   StringView = StringView,
}
