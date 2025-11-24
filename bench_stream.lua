package.path = "build/?.lua;build/?/init.lua;" .. package.path

local Preprocessor = require("pp.preprocessor")
local Parser = require("parser.parser")
local Reporter = require("diag.reporter")

local function read_file(path)
   local fh = io.open(path, "rb")
   if not fh then
      return nil
   end
   local data = fh:read("*a")
   fh:close()
   return data
end

local source = read_file("bench.c") or "int main() { return 0; }"
if #source < 100000 then
   source = string.rep(source, 100)
end

local iterations = 30

local function bench_stream()
   local start = os.clock()
   for _ = 1, iterations do
      local rep = Reporter.new()
      local pp = Preprocessor.preprocess(source, 1, rep, {
         search_paths = { "." },
         defines = {},
         undefs = {},
         current_dir = ".",
         source_path = "bench.c",
      })
      Parser.parse(source, 1, rep, nil, pp.iterator)
   end
   return os.clock() - start
end

print("Source size: " .. #source .. " bytes")
print("Iterations: " .. iterations)
print(string.format("Streamed lexer→PP→parser: %.4f s", bench_stream()))
