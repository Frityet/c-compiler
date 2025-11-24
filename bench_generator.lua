
package.path = "build/?.lua;build/?/init.lua;" .. package.path
local Lexer = require("lexer.lexer")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local source = read_file("bench.c") or "int main() { return 0; }"
-- Duplicate source to make it larger if it's small
if #source < 100000 then
   source = string.rep(source, 100)
end
print("Source size: " .. #source .. " bytes")

local iterations = 50

local function bench_alloc_all()
   local start = os.clock()
   for _ = 1, iterations do
      local tokens = Lexer.lex_all(source, 1)
      local count = #tokens
   end
   return os.clock() - start
end

local function bench_iter_table()
   local start = os.clock()
   for _ = 1, iterations do
      local lex = Lexer.new_lexer(source, 1)
      local count = 0
      while true do
         local tc = Lexer.next_token(lex)
         if tc.kind == Lexer.K_EOF then break end
         local t = Lexer.token_from_c(lex, tc) -- Allocation here
         count = count + 1
      end
   end
   return os.clock() - start
end

local function bench_iter_ffi()
   local start = os.clock()
   for _ = 1, iterations do
      local lex = Lexer.new_lexer(source, 1)
      local count = 0
      while true do
         local tc = Lexer.next_token(lex)
         if tc.kind == Lexer.K_EOF then break end
         -- No allocation, just reading fields
         local k = tc.kind
         count = count + 1
      end
   end
   return os.clock() - start
end

print("Running benchmarks...")

local t_alloc = bench_alloc_all()
print(string.format("Alloc All:   %.4f s", t_alloc))

local t_iter = bench_iter_table()
print(string.format("Iter Table:  %.4f s", t_iter))

local t_ffi = bench_iter_ffi()
print(string.format("Iter FFI:    %.4f s", t_ffi))

print(string.format("Speedup FFI vs Alloc: %.2fx", t_alloc / t_ffi))
