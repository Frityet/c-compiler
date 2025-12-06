local tl_block = require("teal.block")
local BI = tl_block.BLOCK_INDEXES
local type Block = tl_block.Block

local function pipe(pipe_expr: Block, expect: function(Block, string), block: function(string): Block, clone: function(Block): Block): Block
    expect(pipe_expr, "op_bor")

    local calls: {Block} = {}
    local function append_call(expr: Block): nil
        if expr.kind == "op_bor" then
            append_call(expr[BI.OP.E1])
            append_call(expr[BI.OP.E2])
        else
            table.insert(calls, expr)
        end
        return nil
    end
    append_call(pipe_expr)

    --now we need to build the nested function calls
    local invocation: Block = calls[1]
    for i = 2, #calls do
        local call = calls[i]
        if call.kind ~= "op_funcall" then
            local newcall = block("op_funcall")
            newcall[BI.OP.E1] = call
            newcall[BI.OP.E2] = block("expression_list")
            call = newcall
        end

        local exprlist = call[BI.OP.E2]
        if not exprlist then
            exprlist = block "expression_list"
        end

        local newexprlist = clone(exprlist)
        table.insert(newexprlist, 1, invocation)
        invocation = clone(call)
        invocation[BI.OP.E2] = newexprlist
    end
    
    return invocation
end

local function pipe_back(pipe_expr: Block, expect: function(Block, string), block: function(string): Block, clone: function(Block): Block): Block
    expect(pipe_expr, "op_bor")

    local calls: {Block} = {}
    local function append_call(expr: Block): nil
        if expr.kind == "op_bor" then
            append_call(expr[BI.OP.E1])
            append_call(expr[BI.OP.E2])
        else
            table.insert(calls, expr)
        end
        return nil
    end
    append_call(pipe_expr)

    --now we need to build the nested function calls
    local invocation: Block = calls[1]
    for i = 2, #calls do
        local call = calls[i]
        if call.kind ~= "op_funcall" then
            local newcall = block("op_funcall")
            newcall[BI.OP.E1] = call
            newcall[BI.OP.E2] = block("expression_list")
            call = newcall
        end

        local exprlist = call[BI.OP.E2]
        if not exprlist then
            exprlist = block "expression_list"
        end

        local newexprlist = clone(exprlist)
        table.insert(newexprlist, invocation)
        invocation = clone(call)
        invocation[BI.OP.E2] = newexprlist
    end
    
    return invocation
end


return {
    pipe = pipe,
    pipe_back = pipe_back,
}
