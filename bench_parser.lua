package.path = "build/?.lua;build/?/init.lua;" .. package.path

local Lexer = require("lexer.lexer")
local Parser = require("parser.parser")
local Reporter = require("diag.reporter")
local profile = require("jit.p")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then
      return nil
   end
   local content = f:read("*a")
   f:close()
   return content
end

local niter = os.getenv("NITER")
local iterations = niter and tonumber(niter) or 8

local source = read_file("bench.pp.c") or "int main() { return 0; }"
-- Amplify the workload to reduce timing noise without blowing out runtime.
source = string.rep(source, 5)

print("Iterations: " .. iterations)
print("Source size: " .. #source .. " bytes (" .. (#source / 1024) .. " KB)")
print("Total data parsed: " .. (#source * iterations / 1024 / 1024) .. " MB")

local function parse_once()
   local state = Lexer.new_lexer(source, 1)
   local function iter()
      return Lexer.next_token(state)
   end
   local rep = Reporter.new()
   Parser.parse(state.src_ptr, iter, rep, { [1] = state.src_ptr }, { [1] = source })
   if #rep.diagnostics > 0 then
      rep:print_all(10)
      error("Parsing failed with "..#rep.diagnostics.." diagnostics")
   end
end

local function bench_parser()
   local start = os.clock()
   profile.start("l")
   for _ = 1, iterations do
      parse_once()
   end
   profile.stop()
   local elapsed = os.clock() - start
   if os.getenv("PROFILE_REPORT") == "1" then
      local rep = profile.report()
      if rep then
         print("jit.p profile:")
         print(rep)
      end
   end
   return elapsed
end

print("Benchmarking Parser (Lexer + Parser)...")
local t = bench_parser()
print(string.format("Time: %.4f s", t))
print(string.format("Throughput: %.2f MB/s", (iterations * #source / 1024 / 1024) / t))
