local record ffi
    interface CType where type(self) == "ctype"
        metamethod __tostring: function(self): string
    end

    interface CData where type(self) == "cdata"
        metamethod __tostring: function(self): string
    end

    record Pointer<T is CData> is {T}, CData where require("reflect").typeof(self).what == "ptr" end
    record Reference<T is CData> is T, CData where require("reflect").typeof(self).what == "ref" end
    record Array<T is CData> is {T}, CData where require("reflect").typeof(self).what == "array" end
    record Function<T> is CData where require("reflect").typeof(self).what == "func"
        metamethod __call: T
    end
    type NilFunc = Function<nil>

    enum OperatingSystem
        "Windows"
        "Linux"
        "OSX"
        "BSD"
        "POSIX"
        "Solaris"
        "Android"
        "iOS"
        "PS3"
        "PSP"
        "Other"
    end

    enum Architecture
        "x86"
        "x64"
        "arm"
        "arm64"
        "ppc"
        "ppcspe"
        "mips"
        "mipsel"
        "mips64"
        "mips64el"
        "s390x"
        "sparc"
        "other"
    end

    type CNamespace = { string : CData }

    cdef: function(string)
    typeof: function(string | CType | CData): CType
    load: function(string): CNamespace
    new: function<T is CData>(ct: CType | string, ...: any): T
    cast: function<T is CData>(ct: CType | string, ...: any): T
    metatype: function<T is CType>(ct: T | string, metatable: metatable): T
    gc: function<T is CData>(v: T, f: function(T)): T
    sizeof: function(ct: CType | string | CData, nelem?: integer): integer | nil
    alignof: function(ct: CType | string | CData): integer
    offsetof: function(ct: CType | string | CData, field: string): integer, integer | nil, integer | nil
    istype: function(ct: CType | string | CData, v: any): boolean
    errno: function(newerr?: integer): integer
    string: function(ptr: CData, len?: integer): string
    copy: function<T is CData>(dest: Pointer<T>, src: Pointer<T> | string, size: integer)
    fill: function<T is CData>(dest: Pointer<T>, size: integer, value: T)
    abi: function(what: string): boolean

    --here be dragons
    typeinfo: function(x: CType | integer): { string : any }

    C: CNamespace
    arch: Architecture
    os: OperatingSystem
end

return ffi
