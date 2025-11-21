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
local function bench(name, fn)
   local t0 = os.clock()
   local tokens
   for _ = 1, iter do
      tokens = fn()
   end
   local dt = os.clock() - t0
   print(string.format("%-12s %8.3f ms   tokens=%d", name, dt * 1000.0, #tokens))
end

bench("baseline (new)", function()
   return baseline.lex(src, 1, rep)
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
