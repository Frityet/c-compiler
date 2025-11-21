-- Bench preprocessing variants.
-- Usage: ./lua scripts/bench_preprocessors.lua <path-to-c-file> [iterations]

package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;lua_modules/share/lua/5.1/?.lua;lua_modules/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = "lua_modules/lib/lua/5.1/?.so;lua_modules/lib/lua/5.1/?/init.so;" .. package.cpath

local iter = tonumber(arg[2] or "5")
local path = arg[1] or "bench.c"

local fh, err = io.open(path, "r")
if not fh then
   io.stderr:write("failed to read file: " .. tostring(err) .. "\n")
   os.exit(1)
end
local src = fh:read("*a")
fh:close()

local Reporter = require("diag.reporter")
local Preprocessor = require("pp.preprocessor")
local PPFast = require("pp.preprocessor")

local function bench(name, fn)
   local t0 = os.clock()
   local last
   for _ = 1, iter do
      last = fn()
   end
   local dt = os.clock() - t0
   local tok_count = last.tokens and #last.tokens or 0
   local text_len = last.text and #last.text or 0
   print(string.format("%-14s %8.3f ms   tokens=%d  text_len=%d", name, dt * 1000.0, tok_count, text_len))
end

bench("preprocessor", function()
   local rep = Reporter.new()
   return Preprocessor.preprocess(src, 1, rep, { search_paths = { "." }, defines = {}, undefs = {}, current_dir = ".", source_path = path })
end)

bench("pp_fast", function()
   local rep = Reporter.new()
   return PPFast.preprocess(src, 1, rep, { defines = {} })
end)
