local record reflect
    interface Reflect where self.what
        enum What
            "void"
            "int"
            "float"
            "enum"
            "constant"
            "ptr"
            "ref"
            "array"
            "struct"
            "union"
            "func"
            "field"
            "bitfield"
        end
        what: What
    end
    -- field, bitfield.
    interface FieldBase is Reflect where ((function(k: string): boolean return k == "field" or k == "bitfield" end)(self.what))
        offset: number
        type: reflect.Reflect
    end

    -- struct, union, enum, func, field, bitfield, constant.
    interface Named is Reflect where ((function(k: string): boolean return k == "struct" or k == "union" or k == "enum" or k == "func" or k == "field" or k == "bitfield" or k == "constant" end)(self.what))
        name: string | nil
    end

    -- int, float, struct, union, ptr, ref, array, void, enum, bitfield.
    interface Sized is Reflect where ((function(k: string): boolean return k == "int" or k == "float" or k == "struct" or k == "union" or k == "ptr" or k == "ref" or k == "array" or k == "void" or k == "enum" or k == "bitfield" end)(self.what))
        size: number | string
    end

    -- int, float, struct, union, ptr, ref, array, void, enum.
    interface Alignable is Reflect, Sized where ((function(k: string): boolean return k == "int" or k == "float" or k == "struct" or k == "union" or k == "ptr" or k == "ref" or k == "array" or k == "void" or k == "enum" end)(self.what))
        alignment: integer
    end

    -- int, float, struct, union, ptr, ref, array, void.
    interface Attributable is Reflect, Alignable where ((function(k: string): boolean return k == "int" or k == "float" or k == "struct" or k == "union" or k == "ptr" or k == "ref" or k == "array" or k == "void" end)(self.what))
        const: boolean | nil
        volatile: boolean | nil
    end

    -- ptr, ref, array.
    interface HasElementType is Reflect where ((function(k: string): boolean return k == "ptr" or k == "ref" or k == "array" end)(self.what))
        element_type: reflect.Reflect
    end

    -- enum, field, bitfield, constant.
    interface HasBackingType is Reflect where ((function(k: string): boolean return k == "enum" or k == "field" or k == "bitfield" or k == "constant" end)(self.what))
        type: reflect.Reflect
    end

    -- struct, array.
    interface Variable is Reflect where ((function(k: string): boolean return k == "struct" or k == "array" end)(self.what))
        vla: boolean | nil
    end

    -- struct, union.
    interface Composite is Reflect where ((function(k: string): boolean return k == "struct" or k == "union" end)(self.what))
        transparent: boolean | nil

        type Member = reflect.Field | reflect.Bitfield | reflect.Struct | reflect.Union
        members: function(self): function(): Member
        member: function(self, id: string | integer): Member | nil
    end

    record Void is Reflect, Attributable, Alignable, Sized where self.what == "void" end
    record Int is Reflect, Attributable, Alignable, Sized where self.what == "int"
        bool: boolean | nil
        unsigned: boolean | nil
        long: boolean | nil
    end
    record Float is Reflect, Attributable, Alignable, Sized where self.what == "float" end
    record Ptr is Reflect, Attributable, Alignable, Sized, HasElementType where self.what == "ptr" end
    record Ref is Reflect, Attributable, Alignable, Sized, HasElementType where self.what == "ref" end
    record Func is Reflect, Named where self.what == "func"
        sym_name: string
        return_type: reflect.Reflect
        nargs: integer
        vararg: boolean | nil
        sse_reg_params: boolean | nil

        enum Convention
            "cdecl"
            "thiscall"
            "fastcall"
            "stdcall"
        end

        convention: Convention

        arguments: function(self): function(): reflect.Field
        argument: function(self, id: string | integer): reflect.Field | nil
    end
    record Array is Reflect, Attributable, Alignable, Sized, HasElementType, Variable where self.what == "array"
        -- length: integer | nil
        vector: boolean | nil
        complex: boolean | nil
    end
    record Struct is Reflect, Named, Attributable, Alignable, Sized, Variable, Composite where self.what == "struct" end
    record Union is Reflect, Named, Attributable, Alignable, Sized, Composite where self.what == "union" end
    record Enum is Reflect, Named, Alignable, Sized, HasBackingType where self.what == "enum"
        values: function(self): function(): reflect.Constant
        value: function(self, id: string | integer): reflect.Constant | nil
    end
    record Constant is Reflect, Named, HasBackingType where self.what == "constant"
        value: integer
    end
    record Field is FieldBase, Named where self.what == "field" end
    record Bitfield is FieldBase, Named, Sized where self.what == "bitfield" end

    typeof: function(string | any): Reflect
    getmetatable: function<T>(T): metatable<T>
end

return reflect
