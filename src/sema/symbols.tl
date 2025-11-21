local Span = require("util.span")
local types = require("sema.types")

local enum SymbolKind
   "object"
   "function"
   "typedef"
   "tag"
   "enum_const"
   "label"
end

local enum Linkage
   "none"
   "internal"
   "external"
end

local enum StorageDuration
   "auto"
   "static"
   "thread"
end

local record Symbol
   name: string
   kind: SymbolKind
   type: types.TypeNode
   storage: StorageDuration | nil
   linkage: Linkage
   span: Span
   is_tentative: boolean
   is_defined: boolean
   enum_value: integer | nil
end

return {
   SymbolKind = SymbolKind,
   Linkage = Linkage,
   StorageDuration = StorageDuration,
   Symbol = Symbol,
}
