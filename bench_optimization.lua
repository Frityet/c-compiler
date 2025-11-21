package.path = "build/?.lua;build/?/init.lua;" .. package.path
local LexerFFI = require("lexer.lexer_ffi")
local LexerFast = require("lexer.lexer_fast")
local Preprocessor = require("pp.preprocessor")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local source = read_file("bench.c")
if not source then
   print("bench.c not found")
   os.exit(1)
end

local iterations = 20
local warmup = 5

print("Benchmarking with bench.c (" .. #source .. " bytes)")

print("--- Warmup ---")
local start = os.clock()
for _ = 1, warmup do
   LexerFFI.lex(source, 1)
end
print("LexerFFI: " .. (os.clock() - start) .. " seconds for " .. warmup .. " iterations")

start = os.clock()
for _ = 1, warmup do
   LexerFast.lex(source, 1)
end
print("LexerFast: " .. (os.clock() - start) .. " seconds for " .. warmup .. " iterations")

start = os.clock()
for _ = 1, warmup do
   Preprocessor.preprocess(source, 1)
end
print("Preprocessor: " .. (os.clock() - start) .. " seconds for " .. warmup .. " iterations")

print("--- Benchmark ---")
start = os.clock()
for _ = 1, iterations do
   LexerFFI.lex(source, 1)
end
print("LexerFFI: " .. (os.clock() - start) .. " seconds for " .. iterations .. " iterations")

start = os.clock()
for _ = 1, iterations do
   LexerFast.lex(source, 1)
end
print("LexerFast: " .. (os.clock() - start) .. " seconds for " .. iterations .. " iterations")

start = os.clock()
for _ = 1, iterations do
   Preprocessor.preprocess(source, 1)
end
print("Preprocessor: " .. (os.clock() - start) .. " seconds for " .. iterations .. " iterations")
