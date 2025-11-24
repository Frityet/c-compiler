
package.path = "build/?.lua;build/?/init.lua;" .. package.path
local Lexer = require("lexer.lexer")

local function read_file(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local niter = os.getenv("NITER")
local iterations = niter and tonumber(niter) or 20

local source = read_file("bench.c") or "int main() { return 0; }"
source = string.rep(source, 20)

print("Iterations: " .. iterations)
print("Source size: " .. #source .. " bytes (" .. (#source / 1024) .. " KB)")
print("Total data processed: " .. (#source * iterations / 1024 / 1024) .. " MB")


local reporter = {
   error = function(self, msg) end,
   warn = function(self, msg) end
}


local function bench_lex_all()
   local start = os.clock()
   for _ = 1, iterations do
      local tks = Lexer.lex_all(source, 1)
   end
   return os.clock() - start
end

local profile = require("jit.p")

local function bench_lex()
    local start = os.clock()
    profile.start("l")
    for _ = 1, iterations do
        local state = Lexer.new_lexer(source, 1)

        -- local tks = { Lexer.next_token(state) }
        -- while tks[#tks].kind ~= Lexer.K_EOF do
        --     tks[#tks+1] = Lexer.next_token(state)
        -- end
        
        local curtk = Lexer.next_token(state)
        while curtk.kind ~= Lexer.K_EOF do
            curtk = Lexer.next_token(state)
        end
    end
    local t =  os.clock() - start
    profile.stop()
    -- print(profile.report())
    return t
end

print("Benchmarking Lexer (FFI)...")
local t = bench_lex()
print(string.format("Time: %.4f s", t))
print(string.format("Throughput: %.2f MB/s", (iterations * #source / 1024 / 1024) / t))
-- print("Benchmarking Lexer.lex_all (FFI)...")
-- local t_all = bench_lex_all()
-- print(string.format("Time: %.4f s", t_all))
-- print(string.format("Throughput: %.2f MB/s", (iterations * #source / 1024 / 1024) / t_all))
