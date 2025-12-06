local record ffi
    interface CType where type(self) == "ctype"
        metamethod __tostring: function(self): string
    end

    interface CData where type(self) == "cdata"
        metamethod __tostring: function(self): string
    end

    interface Pointer<T is CData> is {T}, CData where require("reflect").typeof(self).what == "ptr"
        metamethod __add: function(self, offset: integer): self
    end
    record CString is {integer}, Pointer<CInteger> where (require as function(string): {string:function(any, x: any): boolean})("ffi").istype("char *", self)
        metamethod __add: function(CString, offset: integer): CString
    end
    type String = CString | string
    interface CInteger is CData where require("reflect").typeof(self).what == "int" end
    interface CFloat is CData where require("reflect").typeof(self).what == "float" end
    interface Reference<T is CData> is T, CData where require("reflect").typeof(self).what == "ref" end
    interface Array<T is CData> is {T}, Pointer<T> where require("reflect").typeof(self).what == "array" end
    
    record Function<T> is CData where require("reflect").typeof(self).what == "func"
        metamethod __call: T
    end
    type NilFunc = Function<function(any): nil>

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

    type CNamespace = { string : any }
    -- record CNamespace is userdata
    --     __index: function<T>(self: CNamespace, key: string): T
    -- end

    cdef: function(string)
    typeof: function(string | CType | CData): CType
    load: function(string): CNamespace
    load: function<T>(string): T
    new: function<T is CData>(ct: CType | string, ...: any): T
    cast: function<T is CData>(ct: CType | string, ...: any): T
    -- cast: function<T is CData>(ct: CType | string, f: function()): Function<function(T): nil>
    interface MetatypeMetatable<T is CData>
        __index: T | function(self: T, key: string): any
        __newindex: function(self: T, key: string, value: any): nil
        __new: function(...: any): T
        __call: function(self: T, ...: any): any
        __tostring: function(self: T): string
        __add: function(self: T, other: any): any
        __sub: function(self: T, other: any): any
        __mul: function(self: T, other: any): any
        __div: function(self: T, other: any): any
        __mod: function(self: T, other: any): any
        __unm: function(self: T): any
        __eq: function(self: T, other: any): boolean
        __lt: function(self: T, other: any): boolean
        __le: function(self: T, other: any): boolean
        __concat: function(self: T, other: any): string
    end
    metatype: function<T is CData>(ct: T | CType | string, metatable: MetatypeMetatable<T>): T
    gc: function<T is CData>(v: T, f: function(T)): T
    sizeof: function(ct: CType | string | CData, nelem?: integer): integer | nil
    alignof: function(ct: CType | string | CData): integer
    offsetof: function(ct: CType | string | CData, field: string): integer, integer | nil, integer | nil
    istype: function(ct: CType | string | CData, v: any): boolean
    errno: function(newerr?: integer): integer
    string: function(ptr: CData, len?: integer): string

    copy: function<T is CData>(dest: T, src: Pointer<T>, size: integer)
    copy: function<T is CData>(dest: T, src: Array<T>, size: integer)
    copy: function<T is CData>(dest: T, src: string, size: integer)
    copy: function<T is CData>(dest: T, src: T, size: integer)

    -- copy: function<T is CData>(dest: Array<T>, src: Pointer<T>, size: integer)
    -- copy: function<T is CData>(dest: Array<T>, src: Array<T>, size: integer)
    -- copy: function<T is CData>(dest: Array<T>, src: string, size: integer)
    -- copy: function<T is CData>(dest: Array<T>, src: T, size: integer)

    -- copy: function<T is CData>(dest: Array<T>, src: Array<T> | string, size: integer)
    -- copy: function<T is CData>(dest: Pointer<T>, src: T, size: integer)
    -- copy: function<T is CData>(dest: Array<T>, src: T, size: integer)
    -- fill: function<T is CData>(dest: Pointer<T>, size: integer, value: T)
    abi: function(what: string): boolean

    --here be dragons
    typeinfo: function(x: CType | integer): { string : any }

    C: CNamespace
    arch: Architecture
    os: OperatingSystem
end

return ffi
