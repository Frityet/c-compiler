local ffi = require("ffi")
local reflect = require("reflect")
local StringBuffer = require("string.buffer")

local MAGIC = 0xDEADBEEF & 0xB00B135

----------------------------------------------------------------------
-- Build a *type descriptor* for any reflect.Reflect
-- (int/float/ptr/ref/array/enum/struct/union/etc.)
----------------------------------------------------------------------

local record TypeDesc
    what: reflect.Reflect.What
    size: number | string | nil
    name: string | nil
    alignment: integer | nil
    const: boolean | nil
    volatile: boolean | nil
    bool: boolean | nil
    unsigned: boolean | nil
    long: boolean | nil
    element: TypeDesc | nil
    vector: boolean | nil
    complex: boolean | nil
    
    record Value
        name: string
        value: number
    end

    values: { Value } | nil
end

local function build_type_desc(ti: reflect.Reflect): TypeDesc
    local desc: TypeDesc = {
        what = ti.what, -- "int", "float", "ptr", "array", "struct", ...
    }

    -- Generic properties
    if ti is reflect.Sized then
        desc.size = ti.size           -- number | string
    end
    if ti is reflect.Named then
        desc.name = ti.name           -- string | nil
    end
    if ti is reflect.Alignable then
        desc.alignment = ti.alignment -- integer
    end
    if ti is reflect.Attributable then
        desc.const    = ti.const or false
        desc.volatile = ti.volatile or false
    end

    -- Int-specific flags
    if ti is reflect.Int then
        desc.bool     = ti.bool or false
        desc.unsigned = ti.unsigned or false
        desc.long     = ti.long or false
    end

    -- Pointer / ref / array: recurse on element type,
    -- but we *never* walk struct/union members here.
    if ti is reflect.HasElementType then
        desc.element = build_type_desc(ti.element_type)
    end

    -- Array-specific flags (length is not exposed in your interface)
    if ti is reflect.Array then
        desc.vector  = ti.vector or false
        desc.complex = ti.complex or false
    end

    -- Enum: record backing type and values, if you care
    if ti is reflect.Enum then
        local values = {}
        local i = 1
        for v in ti:values() do
            values[i] = {
                name  = v.name,
                value = v.value,
            }
            i = i + 1
        end
        desc.values = values
        -- You *could* also serialize ti.type (backing type) if needed
    end

    return desc
end

----------------------------------------------------------------------
-- Build a *struct/union descriptor* (recursively for nested structs).
-- This is the root of what we actually encode.
----------------------------------------------------------------------

local record StructDesc where ((function(k: string): boolean return k == "struct" or k == "union" end)(self.what))
    what: reflect.Reflect.What    -- "struct" or "union"
    name: string | nil
    size: number | string
    alignment: integer
    vla: boolean | nil            -- struct-specific
    transparent: boolean | nil    -- union-specific
    record FieldDesc where ((function(k: string): boolean return k == "field" or k == "bitfield" end)(self.what))
        what: reflect.Reflect.What    -- "field" or "bitfield"
        name: string
        offset: number
        type: TypeDesc
        bits: number | nil            -- bit width, for bitfields
    end
    members: {FieldDesc|StructDesc}    -- fields, bitfields, nested structs/unions
end

local function build_struct_desc(ti: reflect.Reflect): StructDesc
    if not (ti is reflect.Struct) and not (ti is reflect.Union) then
        return error("build_struct_desc: expected struct/union, got "..tostring(ti.what))
    end

    local desc: StructDesc = {
        what       = ti.what,      -- "struct" or "union"
        name       = ti.name,      -- can be nil / anonymous
        size       = ti.size,
        alignment  = ti.alignment,
        members    = {},
    }

    -- Structs have vla flag, composite has 'transparent' flag
    -- if ti is reflect.Variable then
    --     desc.vla = ti.vla or false
    -- end
    if ti is reflect.Composite then
        desc.transparent = ti.transparent or false
    end

    local members = desc.members
    local i = 1

    for m in (ti as reflect.Composite):members() do
        -- Regular fields / bitfields
        if m is reflect.Field or m is reflect.Bitfield then
            local md: StructDesc.FieldDesc = {
                what   = m.what,   -- "field" or "bitfield"
                name   = m.name,
                offset = m.offset,
                type   = build_type_desc(m.type),
            }
            if m is reflect.Bitfield then
                md.bits = m.size as number   -- bit width
            end

            members[i] = md
            i = i + 1

        -- Nested struct / union definitions
        elseif m is reflect.Struct or m is reflect.Union then
            members[i] = build_struct_desc(m)
            i = i + 1

        else
            -- You can decide to error here if you want stricter behaviour.
            -- error("Unsupported member kind: "..tostring(m.what))
        end
    end

    return desc
end

----------------------------------------------------------------------
-- serialise: struct/union -> binary string
--   - x: ffi.CData *or* any reflect.Reflect
--   - buf (optional): existing StringBuffer to append into
-- Returns: binary string (contents of the buffer)
----------------------------------------------------------------------

local function serialise(x: ffi.CData | reflect.Reflect, buf?: StringBuffer): string
    -- Turn cdata instance into its type; or accept a reflect.Reflect directly
    local ti: reflect.Reflect =
        x is ffi.CData and reflect.typeof(x) or x as reflect.Reflect

    if not (ti is reflect.Struct) and not (ti is reflect.Union) then
        return error("Expected struct/union type, got "..tostring(ti.what))
    end

    local schema = build_struct_desc(ti)

    -- If no buffer was provided, we allocate one and write MAGIC once.
    if buf == nil then
        buf = StringBuffer.new()
        buf:encode(MAGIC)
    end

    local pretty = require("pl.pretty")
    -- Encode the schema as a single object
    buf:put(pretty.write(schema as {any:any}, "  ", true))

    -- Return the buffer contents as a binary string
    return buf:tostring()
end

ffi.cdef [[
struct MyStruct {
    int a;
    float b;
    struct {
        char c;
        double d;
    } nested;
};
]]

local my_instance = ffi.new("struct MyStruct", { a = 42, b = 3.14, nested = { c = 65, d = 2.71828 } })

local ser = serialise(my_instance)
print(ser)
