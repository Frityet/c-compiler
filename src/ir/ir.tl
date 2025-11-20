local types = require("sema.types")

local type TypeNode = types.TypeNode

local enum InstrKind
   "binop"
   "unary"
   "load"
   "store"
   "phi"
   "call"
   "ret"
   "br"
   "cbr"
   "gep"
   "cast"
end

local enum BinOp
   "add"
   "sub"
   "mul"
   "div"
   "rem"
   "and"
   "or"
   "xor"
   "shl"
   "shr"
   "cmp_eq"
   "cmp_ne"
   "cmp_lt"
   "cmp_le"
   "cmp_gt"
   "cmp_ge"
end

local record Value
   id: integer
   name: string | nil
   type: TypeNode | nil
end

local interface Instruction where self.kind
   kind: InstrKind
end

local record BinOpInstr
   is Instruction
   where self.kind == "binop"

   op: BinOp
   left: Value
   right: Value
   result: Value
end



local record BasicBlock
   label: string
   instructions: {Instruction}
end

local record IRFunction
   name: string
   params: {Value}
   blocks: {BasicBlock}
   return_type: TypeNode | nil
end

local record Module
   functions: {IRFunction}
end

local function new_value(next_id: integer, name: string | nil, ty: TypeNode | nil): Value
   return { id = next_id, name = name, type = ty }
end

local function new_block(name: string): BasicBlock
   return { label = name, instructions = {} }
end

return {
   InstrKind = InstrKind,
   BinOp = BinOp,
   Value = Value,
   Instruction = Instruction,
   BinOpInstr = BinOpInstr,
   BasicBlock = BasicBlock,
   IRFunction = IRFunction,
   Module = Module,
   new_value = new_value,
   new_block = new_block,
}
