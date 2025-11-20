local isel = require("backend.isel")

local record Allocation
   registers: {integer: string}
end

local record AllocatedFunction
   name: string
   body: {string}
   allocation: Allocation
end

local function allocate_registers(fn: isel.SelectedFunction): AllocatedFunction
   -- TODO: real linear scan register allocator.
   return {
      name = fn.name,
      body = fn.body,
      allocation = { registers = {} },
   }
end

return {
   Allocation = Allocation,
   AllocatedFunction = AllocatedFunction,
   allocate_registers = allocate_registers,
}
