local Span = require("util.span")
local LexerFast = require("lexer.lexer")
local types = require("sema.types")
local ffi = require("ffi")

local type Token = LexerFast.Token
local type TypeNode = types.TypeNode
local TypeQualifier = types.TypeQualifier

local enum ExprKind
   "identifier"
   "number_literal"
   "string_literal"
   "char_literal"
   "unary"
   "binary"
   "conditional"
   "assignment"
   "call"
   "index"
   "field"
   "cast"
   "sizeof"
   "compound_literal"
end

local enum StmtKind
   "decl"
   "expr"
   "null"
   "compound"
   "if"
   "switch"
   "case"
   "default"
   "while"
   "do_while"
   "for"
   "return"
   "break"
   "continue"
   "goto"
   "label"
end

local enum DeclKind
   "var"
   "func"
   "typedef"
   "tag"
end

local enum InitializerKind
   "expr"
   "list"
end

local enum DesignatorKind
   "field"
   "index"
end

local enum StorageClass
   "typedef"
   "extern"
   "static"
   "auto"
   "register"
end

local enum FunctionSpecifier
   "inline"
end

local interface Expr
   is types.ExpressionRef
   where self.kind
   kind: ExprKind
   span: Span
end

local record IdentifierExpr
   is Expr
   where self.kind == "identifier"

   name: Token
end

local record NumberLiteralExpr
   is Expr
   where self.kind == "number_literal"

   token: Token
end

local record StringLiteralExpr
   is Expr
   where self.kind == "string_literal"

   parts: {Token}
end

local record CharLiteralExpr
   is Expr
   where self.kind == "char_literal"

   token: Token
end

local record UnaryExpr
   is Expr
   where self.kind == "unary"

   op: Token
   operand: ExprNode
   postfix: boolean
end

local record BinaryExpr
   is Expr
   where self.kind == "binary"

   op: Token
   lhs: ExprNode
   rhs: ExprNode
end

local record ConditionalExpr
   is Expr
   where self.kind == "conditional"

   cond: ExprNode
   then_expr: ExprNode
   else_expr: ExprNode
end

local record AssignmentExpr
   is Expr
   where self.kind == "assignment"

   op: Token
   lhs: ExprNode
   rhs: ExprNode
end

local record CallExpr
   is Expr
   where self.kind == "call"

   callee: ExprNode
   args: {ExprNode}
end

local record IndexExpr
   is Expr
   where self.kind == "index"

   array: ExprNode
   index: ExprNode
end

local record FieldExpr
   is Expr
   where self.kind == "field"

   receiver: ExprNode
   field: Token
   is_arrow: boolean
end

local record CastExpr
   is Expr
   where self.kind == "cast"

   type_name: TypeName
   value: ExprNode
end

local record SizeofExpr
   is Expr
   where self.kind == "sizeof"

   type_name: TypeName | nil
   expr: ExprNode | nil
end

local record CompoundLiteralExpr
   is Expr
   where self.kind == "compound_literal"

   type_name: TypeName
   init: Initializer
end

local type ExprNode = IdentifierExpr | NumberLiteralExpr | StringLiteralExpr | CharLiteralExpr | UnaryExpr | BinaryExpr | ConditionalExpr | AssignmentExpr | CallExpr | IndexExpr | FieldExpr | CastExpr | SizeofExpr | CompoundLiteralExpr

local record FieldDesignator
   is types.ExpressionRef
   where self.kind == "field"

   kind: DesignatorKind
   span: Span
   name: Token
end

local record IndexDesignator
   is types.ExpressionRef
   where self.kind == "index"

   kind: DesignatorKind
   span: Span
   index: ExprNode
end

local type Designator = FieldDesignator | IndexDesignator

local record InitializerEntry
   designators: {Designator}
   value: Initializer
   span: Span
end

local record ExpressionInitializer
   is types.ExpressionRef
   where self.kind == "expr"

   kind: InitializerKind
   span: Span
   expr: ExprNode
end

local record ListInitializer
   is types.ExpressionRef
   where self.kind == "list"

   kind: InitializerKind
   span: Span
   entries: {InitializerEntry}
end

local type Initializer = ExpressionInitializer | ListInitializer

local record BuiltinTypeSpec
   where self.kind == "builtin"

   kind: string
   span: Span
   builtin: types.BuiltinType
end

local record TypedefTypeSpec
   where self.kind == "typedef"

   kind: string
   span: Span
   name: Token
end

local record StructDeclarator
   span: Span
   declarator: Declarator | nil
   bit_width: ExprNode | nil
end

local record StructField
   span: Span
   specifiers: DeclSpecifiers
   declarators: {StructDeclarator}
end

local record StructSpecifier
   where self.kind == "struct"

   kind: string
   tag_kind: string
   span: Span
   name: Token | nil
   fields: {StructField} | nil
end

local record Enumerator
   name: Token
   value: ExprNode | nil
   span: Span
end

local record EnumSpecifier
   where self.kind == "enum"

   kind: string
   span: Span
   name: Token | nil
   enumerators: {Enumerator} | nil
end

local type TypeSpecifier = BuiltinTypeSpec | TypedefTypeSpec | StructSpecifier | EnumSpecifier

local record DeclSpecifiers
   storage: {StorageClass}
   func_specs: {FunctionSpecifier}
   qualifiers: {TypeQualifier}
   type_spec: TypeSpecifier
   span: Span
end

local record PointerDeclarator
   where self.kind == "pointer"

   kind: string
   span: Span
   qualifiers: {TypeQualifier}
end

local record ArrayDeclarator
   where self.kind == "array"

   kind: string
   span: Span
   qualifiers: {TypeQualifier}
   is_static: boolean
   is_vla: boolean
   size: ExprNode | nil
end

local record FunctionDeclarator
   where self.kind == "function"

   kind: string
   params: {Parameter}
   is_variadic: boolean
end

local type DerivedDeclarator = PointerDeclarator | ArrayDeclarator | FunctionDeclarator

local record Declarator
   name: Token | nil
   derived: {DerivedDeclarator}
   span: Span
end

local record TypeName
   specifiers: DeclSpecifiers
   declarator: Declarator | nil
   type: TypeNode
   span: Span
end

local record Parameter
   specifiers: DeclSpecifiers
   declarator: Declarator | nil
   type: TypeNode
   span: Span
end

local interface Stmt
   kind: StmtKind
   span: Span
end

local record DeclStmt
   is Stmt
   where self.kind == "decl"

   decls: {DeclNode}
end

local record ExprStmt
   is Stmt
   where self.kind == "expr"

   expr: ExprNode
end

local record NullStmt
   is Stmt
   where self.kind == "null"
end

local record CompoundStmt
   is Stmt
   where self.kind == "compound"

   items: {StmtNode}
end

local record IfStmt
   is Stmt
   where self.kind == "if"

   cond: ExprNode
   then_branch: StmtNode
   else_branch: StmtNode | nil
end

local record SwitchStmt
   is Stmt
   where self.kind == "switch"

   expr: ExprNode
   body: StmtNode
end

local record CaseStmt
   is Stmt
   where self.kind == "case"

   expr: ExprNode
   body: StmtNode
end

local record DefaultStmt
   is Stmt
   where self.kind == "default"

   body: StmtNode
end

local record WhileStmt
   is Stmt
   where self.kind == "while"

   cond: ExprNode
   body: StmtNode
end

local record DoWhileStmt
   is Stmt
   where self.kind == "do_while"

   body: StmtNode
   cond: ExprNode
end

local record ForStmt
   is Stmt
   where self.kind == "for"

   init: StmtNode | nil
   cond: ExprNode | nil
   step: ExprNode | nil
   body: StmtNode
end

local record ReturnStmt
   is Stmt
   where self.kind == "return"

   value: ExprNode | nil
end

local record BreakStmt
   is Stmt
   where self.kind == "break"
end

local record ContinueStmt
   is Stmt
   where self.kind == "continue"
end

local record GotoStmt
   is Stmt
   where self.kind == "goto"

   name: Token
end

local record LabelStmt
   is Stmt
   where self.kind == "label"

   name: Token
   body: StmtNode
end

local type StmtNode = DeclStmt | ExprStmt | NullStmt | CompoundStmt | IfStmt | SwitchStmt | CaseStmt | DefaultStmt | WhileStmt | DoWhileStmt | ForStmt | ReturnStmt | BreakStmt | ContinueStmt | GotoStmt | LabelStmt

local interface Decl
   kind: DeclKind
   span: Span
end

local record VarDecl
   is Decl
   where self.kind == "var"

   specifiers: DeclSpecifiers
   declarator: Declarator
   type: TypeNode
   init: Initializer | nil
end

local record FuncDecl
   is Decl
   where self.kind == "func"

   specifiers: DeclSpecifiers
   declarator: Declarator
   type: TypeNode
   body: StmtNode | nil
   old_param_decls: {DeclNode}
end

local record TypedefDecl
   is Decl
   where self.kind == "typedef"

   specifiers: DeclSpecifiers
   declarator: Declarator
   type: TypeNode
end

local record TagDecl
   is Decl
   where self.kind == "tag"

   specifiers: DeclSpecifiers
   type: TypeNode
end

local type DeclNode = VarDecl | FuncDecl | TypedefDecl | TagDecl

local record TranslationUnit
   src_ptr: ffi.CString
   decls: {DeclNode}
end

return {
   ExprKind = ExprKind,
   StmtKind = StmtKind,
   DeclKind = DeclKind,
   InitializerKind = InitializerKind,
   DesignatorKind = DesignatorKind,
   StorageClass = StorageClass,
   FunctionSpecifier = FunctionSpecifier,
   Expr = Expr,
   ExprNode = ExprNode,
   IdentifierExpr = IdentifierExpr,
   NumberLiteralExpr = NumberLiteralExpr,
   StringLiteralExpr = StringLiteralExpr,
   CharLiteralExpr = CharLiteralExpr,
   UnaryExpr = UnaryExpr,
   BinaryExpr = BinaryExpr,
   ConditionalExpr = ConditionalExpr,
   AssignmentExpr = AssignmentExpr,
   CallExpr = CallExpr,
   IndexExpr = IndexExpr,
   FieldExpr = FieldExpr,
   CastExpr = CastExpr,
   SizeofExpr = SizeofExpr,
   CompoundLiteralExpr = CompoundLiteralExpr,
   Designator = Designator,
   FieldDesignator = FieldDesignator,
   IndexDesignator = IndexDesignator,
   InitializerEntry = InitializerEntry,
   ExpressionInitializer = ExpressionInitializer,
   ListInitializer = ListInitializer,
   Initializer = Initializer,
   BuiltinTypeSpec = BuiltinTypeSpec,
   TypedefTypeSpec = TypedefTypeSpec,
   StructDeclarator = StructDeclarator,
   StructField = StructField,
   StructSpecifier = StructSpecifier,
   Enumerator = Enumerator,
   EnumSpecifier = EnumSpecifier,
   TypeSpecifier = TypeSpecifier,
   DeclSpecifiers = DeclSpecifiers,
   PointerDeclarator = PointerDeclarator,
   ArrayDeclarator = ArrayDeclarator,
   FunctionDeclarator = FunctionDeclarator,
   DerivedDeclarator = DerivedDeclarator,
   Declarator = Declarator,
   TypeName = TypeName,
   Parameter = Parameter,
   Stmt = Stmt,
   StmtNode = StmtNode,
   DeclStmt = DeclStmt,
   ExprStmt = ExprStmt,
   NullStmt = NullStmt,
   CompoundStmt = CompoundStmt,
   IfStmt = IfStmt,
   SwitchStmt = SwitchStmt,
   CaseStmt = CaseStmt,
   DefaultStmt = DefaultStmt,
   WhileStmt = WhileStmt,
   DoWhileStmt = DoWhileStmt,
   ForStmt = ForStmt,
   ReturnStmt = ReturnStmt,
   BreakStmt = BreakStmt,
   ContinueStmt = ContinueStmt,
   GotoStmt = GotoStmt,
   LabelStmt = LabelStmt,
   Decl = Decl,
   DeclNode = DeclNode,
   VarDecl = VarDecl,
   FuncDecl = FuncDecl,
   TypedefDecl = TypedefDecl,
   TagDecl = TagDecl,
   TranslationUnit = TranslationUnit,
}
