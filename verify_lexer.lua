package.path = "build/?.lua;build/?/init.lua;" .. package.path
local ffi = require("ffi")
local LexerFFI = require("lexer.lexer_ffi")
local LexerFast = require("lexer.lexer_fast")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local source = read_file("bench.c")
if not source then
   print("Could not read bench.c")
   os.exit(1)
end

print("Lexing with LexerFFI...")
local buf1 = LexerFFI.lex(source, 1)
print("Lexing with LexerFast...")
local buf2 = LexerFast.lex(source, 1)

print("Comparing results...")
print("Count: FFI=" .. buf1.count .. " Fast=" .. buf2.count)

if buf1.count ~= buf2.count then
   print("MISMATCH: Token count differs!")
   -- os.exit(1) -- Continue to see where it differs
end

local limit = math.min(buf1.count, buf2.count)
local errors = 0
for i = 0, limit - 1 do
   local t1 = buf1.data[i]
   local t2 = buf2.data[i]
   
   local mismatch = false
   if t1.kind ~= t2.kind then mismatch = true end
   if t1.start ~= t2.start then mismatch = true end
   if t1.stop ~= t2.stop then mismatch = true end
   if t1.line ~= t2.line then mismatch = true end
   if t1.col ~= t2.col then mismatch = true end
   
   if mismatch then
      print(string.format("MISMATCH at index %d:", i))
      print(string.format("  FFI:  kind=%d start=%d stop=%d line=%d col=%d", t1.kind, t1.start, t1.stop, t1.line, t1.col))
      print(string.format("  Fast: kind=%d start=%d stop=%d line=%d col=%d", t2.kind, t2.start, t2.stop, t2.line, t2.col))
      
      local s1 = LexerFFI.lexeme(buf1, i)
      local s2 = LexerFast.lexeme(buf2, i)
      print("  Lexeme FFI:  " .. tostring(s1))
      print("  Lexeme Fast: " .. tostring(s2))
      
      errors = errors + 1
      if errors > 10 then
         print("Too many errors, stopping.")
         os.exit(1)
      end
   end
end

if errors == 0 and buf1.count == buf2.count then
   print("VERIFICATION PASSED!")
else
   print("VERIFICATION FAILED with " .. errors .. " mismatches.")
   os.exit(1)
end
