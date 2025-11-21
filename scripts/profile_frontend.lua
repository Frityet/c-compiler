-- Usage: luajit scripts/profile_frontend.lua <path-to-c-file> [iterations]
-- Profiles preprocess + parse using jit.profile (jit.p) and prints top stacks.

package.path = "build/?.lua;build/?/init.lua;src/?.lua;src/?/init.lua;lua_modules/share/lua/5.1/?.lua;lua_modules/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = "lua_modules/lib/lua/5.1/?.so;lua_modules/lib/lua/5.1/?/init.so;" .. package.cpath

local profile = require("jit.profile")
local Reporter = require("diag.reporter")
local Preprocessor = require("pp.preprocessor")
local Parser = require("parser.parser")

local path = arg[1] or "bench.c"
local iters = tonumber(arg[2] or "1")
local fh, err = io.open(path, "r")
if not fh then
   io.stderr:write("failed to read " .. tostring(err) .. "\n")
   os.exit(1)
end
local src = fh:read("*a")
fh:close()

local function path_dir(p)
   return p:match("^(.*)/[^/]+$") or "."
end

local samples = {}
local function on_sample(thread, count, vmstate)
   local frame = profile.dumpstack(thread, "f", 1)
   if frame == "" then
      frame = vmstate
   end
   local key = vmstate .. ":" .. frame
   samples[key] = (samples[key] or 0) + (count or 1)
end

local function run_once()
   local rep = Reporter.new()
   local pp = Preprocessor.preprocess(src, 1, rep, {
      search_paths = { path_dir(path) },
      defines = {},
      undefs = {},
      current_dir = path_dir(path),
      source_path = path,
   })
   Parser.parse(pp.text, 1, rep, pp.tokens)
end

profile.start("fi10", on_sample)
local t0 = os.clock()
for _ = 1, iters do
   run_once()
end
local dt = os.clock() - t0
profile.stop()

local entries = {}
for k, v in pairs(samples) do
   entries[#entries + 1] = { k, v }
end
table.sort(entries, function(a, b)
   return a[2] > b[2]
end)

print(string.format("total %.3f ms over %d iteration(s)", dt * 1000.0, iters))
for i = 1, math.min(25, #entries) do
   local e = entries[i]
   print(string.format("%7d  %s", e[2], e[1]))
end
