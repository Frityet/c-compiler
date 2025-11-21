-- Usage: luajit scripts/bench_lexers.lua <path-to-c-file> [iterations]
-- Benchmarks the baseline lexer vs the StringZilla-powered lexer (if available).


--max pref
-- collectgarbage("stop")
-- collectgarbage("stop")

package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path

local iter = tonumber(arg[2] or "10")
local path = arg[1]
if not path then
   io.stderr:write("usage: luajit scripts/bench_lexers.lua <path-to-c-file> [iterations]\n")
   os.exit(1)
end

local fh, err = io.open(path, "r")
if not fh then
   io.stderr:write("failed to read file: " .. tostring(err) .. "\n")
   os.exit(1)
end
local src = fh:read("*a")
fh:close()

local Reporter = require("diag.reporter")
local rep = Reporter.new()

local baseline = require("lexer.lexer")
local ffi_lexer = require("lexer.lexer_ffi")
-- local fast_lexer = require("lexer.lexer_fast")
local function count_tokens(result)
   if type(result) == "function" then
      local n = 0
      while true do
         local t = result()
         n = n + 1
         if t.kind == "eof" then
            break
         end
      end
      return n
   end
   if (type(result) == "cdata" or type(result) == "table") and result.count then
      return tonumber(result.count)
   end
   return #result
end

local function bench(name, fn)
   local t0 = os.clock()
    local count = 0
   for _ = 1, iter do
      count = count_tokens(fn())
   end
   local dt = os.clock() - t0
   print(string.format("%-14s %8.3f ms   tokens=%d", name, dt * 1000.0, count))
end

bench("baseline (gen)", function()
   return baseline.lex(src, 1, rep)
end)

bench("ffi (buffer)", function()
   return ffi_lexer.lex(src, 1)
end)

bench("ffi (tokens)", function()
   local lb = ffi_lexer.lex(src, 1)
   return ffi_lexer.to_token_array(lb)
end)

local ok, old_lexer = pcall(require, "lexer.lexer_old")
if ok then
   bench("old lexer", function()
      return old_lexer.lex(src, 1, rep)
   end)
else
   print("old lexer unavailable: " .. tostring(old_lexer))
end


-- Add a simple throughput metric (bytes per second) if both ran.
if ok then
   print(string.format("Input bytes: %d", #src))
end
