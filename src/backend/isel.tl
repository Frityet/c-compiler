local ir = require("ir.ir")

local record SelectedFunction
   name: string
   body: {string}
end

local function select_function(fn: ir.IRFunction): SelectedFunction
   -- TODO: real instruction selection lowering IR to target-specific ops.
   return { name = fn.name, body = {} }
end

return {
   SelectedFunction = SelectedFunction,
   select_function = select_function,
}
