local _tl_compat; if (tonumber((_VERSION or ''):match('[%d.]*$')) or 0) < 5.3 then local p, m = true, require('compat53.module'); if p then _tl_compat = m end end; local math = _tl_compat and _tl_compat.math or math; local string = _tl_compat and _tl_compat.string or string; local tl_block = require("teal.block")
local BI = tl_block.BLOCK_INDEXES


local function char(x, expect, block)
   expect(x, "string")

   local function unquote(s)
      if #s >= 2 then
         local first = string.sub(s, 1, 1)
         local last = string.sub(s, -1, -1)
         if (first == '"' and last == '"') or (first == "'" and last == "'") then
            return string.sub(s, 2, -2)
         end
      end
      return s
   end

   local code = string.byte(unquote(x.tk), 1)
   local raw = unquote(x.tk)

   if code == string.byte("\\") and #raw >= 2 then
      local esc_byte = string.byte(raw, 2)
      if esc_byte == string.byte("n") then
         code = 10
      elseif esc_byte == string.byte("r") then
         code = 13
      elseif esc_byte == string.byte("t") then
         code = 9
      elseif esc_byte == string.byte("\\") then
         code = 92
      elseif esc_byte == string.byte("'") then
         code = 39
      elseif esc_byte == string.byte('"') then
         code = 34
      elseif esc_byte >= string.byte("0") and esc_byte <= string.byte("9") then
         local oct = tonumber(string.sub(raw, 2), 8)
         if oct ~= nil then
            local n = math.tointeger(oct)
            if n ~= nil then code = n end
         end
      elseif esc_byte == string.byte("x") and #raw >= 3 then
         local hex = tonumber(string.sub(raw, 3), 16)
         if hex ~= nil then
            local n = math.tointeger(hex)
            if n ~= nil then code = n end
         end
      else
         code = esc_byte
      end
   end

   local n = block("integer")
   n.tk = tostring(code)
   return n
end

return {
   char = char,
}
