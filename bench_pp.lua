
package.path = "build/?.lua;build/?/init.lua;" .. package.path
local PP = require("pp.preprocessor")
local LexerFast = require("lexer.lexer")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local source = read_file("bench.c") or "int main() { return 0; }"
-- Duplicate source to make it larger
if #source < 100000 then
   source = string.rep(source, 100)
end
print("Source size: " .. #source .. " bytes")

local niter = os.getenv("NITER")
local iterations = niter and tonumber(niter) or 20

local reporter = {
   report = function() end,
}


local function bench_pp()
   local start = os.clock()
   local profile_mode = os.getenv("PROFILE")
   local p
   if profile_mode then
      p = require("jit.p")
      p.start(profile_mode)
   end
   for _ = 1, iterations do
      local pp = PP.preprocess(source, 1, reporter)
      local count = 0
      while true do
         local t = pp.next()
         if t.kind == LexerFast.K_EOF then break end
         count = count + 1
      end
   end
   if p then
      p.stop()
   end
   return os.clock() - start
end

print("Benchmarking Preprocessor (FFI)...")
local t = bench_pp()
print(string.format("Time: %.4f s", t))
print(string.format("Throughput: %.2f MB/s", (iterations * #source / 1024 / 1024) / t))
