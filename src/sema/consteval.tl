local function unary(op: string, val: integer | nil): integer | nil
   if val is nil then
      return nil
   end
   if op == "-" then
      return -val
   elseif op == "+" then
      return val
   elseif op == "!" then
      return val == 0 and 1 or 0
   elseif op == "~" then
      return -1 - val
   end
   return nil
end

local function lshift(lhs: integer, rhs: integer): integer
   if rhs < 0 then
      return lhs
   end
   return math.floor(lhs * (2 ^ rhs))
end

local function rshift(lhs: integer, rhs: integer): integer
   if rhs < 0 then
      return lhs
   end
   local denom = 2 ^ rhs
   if denom == 0 then
      return lhs
   end
   if lhs >= 0 then
      return math.floor(lhs / denom)
   end
   return -math.floor((-lhs) / denom)
end

local function binary(op: string, lhs: integer | nil, rhs: integer | nil): integer | nil
   if lhs is nil or rhs is nil then
      return nil
   end
   if op == "+" then
      return lhs + rhs
   elseif op == "-" then
      return lhs - rhs
   elseif op == "*" then
      return lhs * rhs
   elseif op == "/" then
      if rhs == 0 then return nil end
      return math.floor(lhs / rhs)
   elseif op == "%" then
      if rhs == 0 then return nil end
      return lhs % rhs
   elseif op == "<<" then
      return lshift(lhs, rhs)
   elseif op == ">>" then
      return rshift(lhs, rhs)
   elseif op == "&" then
      return lhs & rhs
   elseif op == "|" then
      return lhs | rhs
   elseif op == "^" then
      return lhs ~ rhs
   elseif op == "==" then
      return lhs == rhs and 1 or 0
   elseif op == "!=" then
      return lhs ~= rhs and 1 or 0
   elseif op == "<" then
      return lhs < rhs and 1 or 0
   elseif op == ">" then
      return lhs > rhs and 1 or 0
   elseif op == "<=" then
      return lhs <= rhs and 1 or 0
   elseif op == ">=" then
      return lhs >= rhs and 1 or 0
   elseif op == "&&" then
      return (lhs ~= 0 and rhs ~= 0) and 1 or 0
   elseif op == "||" then
      return (lhs ~= 0 or rhs ~= 0) and 1 or 0
   end
   return nil
end

return {
   unary = unary,
   binary = binary,
}
