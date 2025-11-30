local ffi = require("ffi")
local Span = require("util.span")
local TLStringView = require("util.string_view")
local LexerFast = require("lexer.lexer")
local types = require("sema.types-ffi")

local type TLToken = LexerFast.Token
local type TypeNode = types.TypeNode

ffi.cdef [[
union ExprNode;
union StatementNode;
union DeclarationNode;
union Initializer;
union Designator;
union DerivedDeclarator;
union TypeSpecifier;

struct DeclarationSpecifiers;
struct TypeName;
struct Parameter;
struct Declarator;
struct StructField;
struct StructDeclarator;
struct Enumerator;
struct InitializerEntry;
struct SourceReference;
struct SourcePointer;

typedef tl_token_fast TLToken;

enum ExprKind {
   ExprKind_IDENTIFIER,
   ExprKind_NUMBER_LITERAL,
   ExprKind_STRING_LITERAL,
   ExprKind_CHAR_LITERAL,
   ExprKind_UNARY,
   ExprKind_BINARY,
   ExprKind_CONDITIONAL,
   ExprKind_ASSIGNMENT,
   ExprKind_CALL,
   ExprKind_INDEX,
   ExprKind_FIELD,
   ExprKind_CAST,
   ExprKind_SIZEOF,
   ExprKind_COMPOUND_LITERAL,
};

enum StatementKind {
   StatementKind_DECLARATION,
   StatementKind_EXPRESSION,
   StatementKind_NULL,
   StatementKind_COMPOUND,
   StatementKind_IF,
   StatementKind_SWITCH,
   StatementKind_CASE,
   StatementKind_DEFAULT,
   StatementKind_WHILE,
   StatementKind_DO_WHILE,
   StatementKind_FOR,
   StatementKind_RETURN,
   StatementKind_BREAK,
   StatementKind_CONTINUE,
   StatementKind_GOTO,
   StatementKind_LABEL,
};

enum DeclarationKind {
   DeclarationKind_VARIABLE,
   DeclarationKind_FUNCTION,
   DeclarationKind_TYPEDEF,
   DeclarationKind_TAG,
};

enum InitializerKind {
   InitializerKind_EXPR,
   InitializerKind_LIST,
};

enum DesignatorKind {
   DesignatorKind_FIELD,
   DesignatorKind_INDEX,
};

enum StorageClass {
   StorageClass_TYPEDEF,
   StorageClass_EXTERN,
   StorageClass_STATIC,
   StorageClass_AUTO,
   StorageClass_REGISTER,
};

enum FunctionSpecifier {
   FunctionSpecifier_INLINE,
};

enum TagKind {
   TagKind_STRUCT,
   TagKind_UNION,
};

enum DerivedDeclaratorKind {
   DerivedDeclarator_POINTER,
   DerivedDeclarator_ARRAY,
   DerivedDeclarator_FUNCTION,
};

enum TypeSpecifierKind {
   TypeSpecifierKind_BUILTIN,
   TypeSpecifierKind_TYPEDEF,
   TypeSpecifierKind_STRUCT,
   TypeSpecifierKind_ENUM,
};

struct ExpressionBase {
   enum ExprKind kind;
   struct TLSpan span;
};

struct StatementBase {
   enum StatementKind kind;
   struct TLSpan span;
};

struct DeclarationBase {
   enum DeclarationKind kind;
   struct TLSpan span;
};

struct DesignatorBase {
   enum DesignatorKind kind;
   struct TLSpan span;
};

struct InitializerBase {
   enum InitializerKind kind;
   struct TLSpan span;
};

struct TypeSpecifierBase {
   enum TypeSpecifierKind kind;
   struct TLSpan span;
};

struct DerivedDeclaratorBase {
   enum DerivedDeclaratorKind kind;
   struct TLSpan span;
};

struct IdentifierExpr {
   struct ExpressionBase;
   TLToken name;
};

struct NumberLiteralExpr {
   struct ExpressionBase;
   TLToken token;
};

struct StringLiteralExpr {
   struct ExpressionBase;
   TLToken *parts;
   size_t parts_len;
};

struct CharLiteralExpr {
   struct ExpressionBase;
   TLToken token;
};

struct UnaryExpr {
   struct ExpressionBase;
   TLToken op;
   union ExprNode *operand;
   bool postfix;
};

struct BinaryExpr {
   struct ExpressionBase;
   TLToken op;
   union ExprNode *lhs;
   union ExprNode *rhs;
};

struct ConditionalExpr {
   struct ExpressionBase;
   union ExprNode *cond;
   union ExprNode *then_expr;
   union ExprNode *else_expr;
};

struct AssignmentExpr {
   struct ExpressionBase;
   TLToken op;
   union ExprNode *lhs;
   union ExprNode *rhs;
};

struct CallExpr {
   struct ExpressionBase;
   union ExprNode *callee;
   union ExprNode **args;
   size_t args_len;
};

struct IndexExpr {
   struct ExpressionBase;
   union ExprNode *array;
   union ExprNode *index;
};

struct FieldExpr {
   struct ExpressionBase;
   union ExprNode *receiver;
   TLToken field;
   bool is_arrow;
};

struct CastExpr {
   struct ExpressionBase;
   struct TypeName *type_name;
   union ExprNode *value;
};

struct SizeofExpr {
   struct ExpressionBase;
   struct TypeName *type_name;
   union ExprNode *expr;
};

struct CompoundLiteralExpr {
   struct ExpressionBase;
   struct TypeName *type_name;
   union Initializer *init;
};

union ExprNode {
   struct IdentifierExpr;
   struct NumberLiteralExpr;
   struct StringLiteralExpr;
   struct CharLiteralExpr;
   struct UnaryExpr;
   struct BinaryExpr;
   struct ConditionalExpr;
   struct AssignmentExpr;
   struct CallExpr;
   struct IndexExpr;
   struct FieldExpr;
   struct CastExpr;
   struct SizeofExpr;
   struct CompoundLiteralExpr;
};

struct FieldDesignator {
   struct DesignatorBase;
   TLToken name;
};

struct IndexDesignator {
   struct DesignatorBase;
   union ExprNode *index;
};

union Designator {
   struct FieldDesignator;
   struct IndexDesignator;
};

struct InitializerEntry {
   union Designator **designators;
   size_t designators_len;
   union Initializer *value;
   struct TLSpan span;
};

struct ExpressionInitializer {
   struct InitializerBase;
   union ExprNode *expr;
};

struct ListInitializer {
   struct InitializerBase;
   struct InitializerEntry *entries;
   size_t entries_len;
};

union Initializer {
   struct ExpressionInitializer;
   struct ListInitializer;
};

struct BuiltinTypeSpec {
   struct TypeSpecifierBase;
   union TypeNode *builtin;
};

struct TypedefTypeSpec {
   struct TypeSpecifierBase;
   TLToken name;
};

struct StructDeclarator {
   struct TLSpan span;
   struct Declarator *declarator;
   union ExprNode *bit_width;
};

struct StructField {
   struct TLSpan span;
   struct DeclarationSpecifiers *specifiers;
   struct StructDeclarator *declarators;
   size_t declarators_len;
};

struct StructSpecifier {
   struct TypeSpecifierBase;
   enum TagKind tag_kind;
   TLToken name;
   bool has_name;
   struct StructField *fields;
   size_t fields_len;
   bool has_fields;
};

struct Enumerator {
   tl_token_fast name;
   union ExprNode *value;
   struct TLSpan span;
};

struct EnumSpecifier {
   struct TypeSpecifierBase;
   TLToken name;
   bool has_name;
   struct Enumerator *enumerators;
   size_t enumerators_len;
   bool has_enumerators;
};

union TypeSpecifier {
   struct BuiltinTypeSpec;
   struct TypedefTypeSpec;
   struct StructSpecifier;
   struct EnumSpecifier;
};

struct DeclarationSpecifiers {
   enum StorageClass *storage;
   size_t storage_len;
   enum FunctionSpecifier *func_specs;
   size_t func_specs_len;
   uint8_t qualifiers_len;
   enum CType_TypeQualifier qualifiers[3];
   union TypeSpecifier *type_spec;
   struct TLSpan span;
};

struct PointerDeclarator {
   struct DerivedDeclaratorBase;
   uint8_t qualifiers_len;
   enum CType_TypeQualifier qualifiers[3];
};

struct ArrayDeclarator {
   struct DerivedDeclaratorBase;
   uint8_t qualifiers_len;
   enum CType_TypeQualifier qualifiers[3];
   bool is_static;
   bool is_vla;
   union ExprNode *size;
};

struct FunctionDeclarator {
   struct DerivedDeclaratorBase;
   struct Parameter *params;
   size_t params_len;
   bool is_variadic;
};

union DerivedDeclarator {
   struct PointerDeclarator;
   struct ArrayDeclarator;
   struct FunctionDeclarator;
};

struct Declarator {
   tl_token_fast name;
   bool has_name;
   union DerivedDeclarator **derived;
   size_t derived_len;
   struct TLSpan span;
};

struct TypeName {
   struct DeclarationSpecifiers *specifiers;
   struct Declarator *declarator;
   bool has_declarator;
   union TypeNode *type;
   struct TLSpan span;
};

struct Parameter {
   struct DeclarationSpecifiers *specifiers;
   struct Declarator *declarator;
   bool has_declarator;
   union TypeNode *type;
   struct TLSpan span;
};

struct DeclarationStatement {
   struct StatementBase;
   union DeclarationNode **decls;
   size_t decls_len;
};

struct ExpressionStatement {
   struct StatementBase;
   union ExprNode *expr;
};

struct NullStatement {
   struct StatementBase;
};

struct CompoundStatement {
   struct StatementBase;
   union StatementNode **items;
   size_t items_len;
};

struct IfStatement {
   struct StatementBase;
   union ExprNode *cond;
   union StatementNode *then_branch;
   union StatementNode *else_branch;
};

struct SwitchStatement {
   struct StatementBase;
   union ExprNode *expr;
   union StatementNode *body;
};

struct CaseStatement {
   struct StatementBase;
   union ExprNode *expr;
   union StatementNode *body;
};

struct DefaultStatement {
   struct StatementBase;
   union StatementNode *body;
};

struct WhileStatement {
   struct StatementBase;
   union ExprNode *cond;
   union StatementNode *body;
};

struct DoWhileStatement {
   struct StatementBase;
   union StatementNode *body;
   union ExprNode *cond;
};

struct ForStatement {
   struct StatementBase;
   union StatementNode *init;
   union ExprNode *cond;
   union ExprNode *step;
   union StatementNode *body;
};

struct ReturnStatement {
   struct StatementBase;
   union ExprNode *value;
};

struct BreakStatement {
   struct StatementBase;
};

struct ContinueStatement {
   struct StatementBase;
};

struct GotoStatement {
   struct StatementBase;
   TLToken name;
};

struct LabelStatement {
   struct StatementBase;
   TLToken name;
   union StatementNode *body;
};

union StatementNode {
   struct DeclarationStatement;
   struct ExpressionStatement;
   struct NullStatement;
   struct CompoundStatement;
   struct IfStatement;
   struct SwitchStatement;
   struct CaseStatement;
   struct DefaultStatement;
   struct WhileStatement;
   struct DoWhileStatement;
   struct ForStatement;
   struct ReturnStatement;
   struct BreakStatement;
   struct ContinueStatement;
   struct GotoStatement;
   struct LabelStatement;
};

struct VariableDeclaration {
   struct DeclarationBase;
   struct DeclarationSpecifiers *specifiers;
   struct Declarator *declarator;
   union TypeNode *type;
   union Initializer *init;
};

struct FunctionDeclaration {
   struct DeclarationBase;
   struct DeclarationSpecifiers *specifiers;
   struct Declarator *declarator;
   union TypeNode *type;
   union StatementNode *body;
   union DeclarationNode **old_param_decls;
   size_t old_param_decls_len;
};

struct TypedefDeclaration {
   struct DeclarationBase;
   struct DeclarationSpecifiers *specifiers;
   struct Declarator *declarator;
   union TypeNode *type;
};

struct TagDeclaration {
   struct DeclarationBase;
   struct DeclarationSpecifiers *specifiers;
   union TypeNode *type;
};

union DeclarationNode {
   struct VariableDeclaration;
   struct FunctionDeclaration;
   struct TypedefDeclaration;
   struct TagDeclaration;
};

struct SourceReference {
   int file_id;
   struct TLStringView source;
};

struct SourcePointer {
   int file_id;
   const char *ptr;
};

struct TranslationUnit {
   const char *src_ptr;
   struct SourceReference *src_refs;
   size_t src_refs_len;
   struct SourcePointer *src_ptrs;
   size_t src_ptrs_len;
   union DeclarationNode **decls;
   size_t decls_len;
};
]]

local EXPR_IDENTIFIER<const> = ffi.C.ExprKind_IDENTIFIER as integer
local EXPR_NUMBER_LITERAL<const> = ffi.C.ExprKind_NUMBER_LITERAL as integer
local EXPR_STRING_LITERAL<const> = ffi.C.ExprKind_STRING_LITERAL as integer
local EXPR_CHAR_LITERAL<const> = ffi.C.ExprKind_CHAR_LITERAL as integer
local EXPR_UNARY<const> = ffi.C.ExprKind_UNARY as integer
local EXPR_BINARY<const> = ffi.C.ExprKind_BINARY as integer
local EXPR_CONDITIONAL<const> = ffi.C.ExprKind_CONDITIONAL as integer
local EXPR_ASSIGNMENT<const> = ffi.C.ExprKind_ASSIGNMENT as integer
local EXPR_CALL<const> = ffi.C.ExprKind_CALL as integer
local EXPR_INDEX<const> = ffi.C.ExprKind_INDEX as integer
local EXPR_FIELD<const> = ffi.C.ExprKind_FIELD as integer
local EXPR_CAST<const> = ffi.C.ExprKind_CAST as integer
local EXPR_SIZEOF<const> = ffi.C.ExprKind_SIZEOF as integer
local EXPR_COMPOUND_LITERAL<const> = ffi.C.ExprKind_COMPOUND_LITERAL as integer

local STATEMENT_DECLARATION<const> = ffi.C.StatementKind_DECLARATION as integer
local STATEMENT_EXPRESSION<const> = ffi.C.StatementKind_EXPRESSION as integer
local STATEMENT_NULL<const> = ffi.C.StatementKind_NULL as integer
local STATEMENT_COMPOUND<const> = ffi.C.StatementKind_COMPOUND as integer
local STATEMENT_IF<const> = ffi.C.StatementKind_IF as integer
local STATEMENT_SWITCH<const> = ffi.C.StatementKind_SWITCH as integer
local STATEMENT_CASE<const> = ffi.C.StatementKind_CASE as integer
local STATEMENT_DEFAULT<const> = ffi.C.StatementKind_DEFAULT as integer
local STATEMENT_WHILE<const> = ffi.C.StatementKind_WHILE as integer
local STATEMENT_DO_WHILE<const> = ffi.C.StatementKind_DO_WHILE as integer
local STATEMENT_FOR<const> = ffi.C.StatementKind_FOR as integer
local STATEMENT_RETURN<const> = ffi.C.StatementKind_RETURN as integer
local STATEMENT_BREAK<const> = ffi.C.StatementKind_BREAK as integer
local STATEMENT_CONTINUE<const> = ffi.C.StatementKind_CONTINUE as integer
local STATEMENT_GOTO<const> = ffi.C.StatementKind_GOTO as integer
local STATEMENT_LABEL<const> = ffi.C.StatementKind_LABEL as integer

local DECLARATION_VARIABLE<const> = ffi.C.DeclarationKind_VARIABLE as integer
local DECLARATION_FUNCTION<const> = ffi.C.DeclarationKind_FUNCTION as integer
local DECLARATION_TYPEDEF<const> = ffi.C.DeclarationKind_TYPEDEF as integer
local DECLARATION_TAG<const> = ffi.C.DeclarationKind_TAG as integer

local INIT_EXPR<const> = ffi.C.InitializerKind_EXPR as integer
local INIT_LIST<const> = ffi.C.InitializerKind_LIST as integer

local DESIG_FIELD<const> = ffi.C.DesignatorKind_FIELD as integer
local DESIG_INDEX<const> = ffi.C.DesignatorKind_INDEX as integer

local STORAGE_TYPEDEF<const> = ffi.C.StorageClass_TYPEDEF as integer
local STORAGE_EXTERN<const> = ffi.C.StorageClass_EXTERN as integer
local STORAGE_STATIC<const> = ffi.C.StorageClass_STATIC as integer
local STORAGE_AUTO<const> = ffi.C.StorageClass_AUTO as integer
local STORAGE_REGISTER<const> = ffi.C.StorageClass_REGISTER as integer

local FUNC_INLINE<const> = ffi.C.FunctionSpecifier_INLINE as integer

local TAG_STRUCT<const> = ffi.C.TagKind_STRUCT as integer
local TAG_UNION<const> = ffi.C.TagKind_UNION as integer

local DERIVED_POINTER<const> = ffi.C.DerivedDeclarator_POINTER as integer
local DERIVED_ARRAY<const> = ffi.C.DerivedDeclarator_ARRAY as integer
local DERIVED_FUNCTION<const> = ffi.C.DerivedDeclarator_FUNCTION as integer

local TYPESPEC_BUILTIN<const> = ffi.C.TypeSpecifierKind_BUILTIN as integer
local TYPESPEC_TYPEDEF<const> = ffi.C.TypeSpecifierKind_TYPEDEF as integer
local TYPESPEC_STRUCT<const> = ffi.C.TypeSpecifierKind_STRUCT as integer
local TYPESPEC_ENUM<const> = ffi.C.TypeSpecifierKind_ENUM as integer

local ExprKind = {
   IDENTIFIER = EXPR_IDENTIFIER,
   NUMBER_LITERAL = EXPR_NUMBER_LITERAL,
   STRING_LITERAL = EXPR_STRING_LITERAL,
   CHAR_LITERAL = EXPR_CHAR_LITERAL,
   UNARY = EXPR_UNARY,
   BINARY = EXPR_BINARY,
   CONDITIONAL = EXPR_CONDITIONAL,
   ASSIGNMENT = EXPR_ASSIGNMENT,
   CALL = EXPR_CALL,
   INDEX = EXPR_INDEX,
   FIELD = EXPR_FIELD,
   CAST = EXPR_CAST,
   SIZEOF = EXPR_SIZEOF,
   COMPOUND_LITERAL = EXPR_COMPOUND_LITERAL,
}

local StatementKind = {
   DECLARATION = STATEMENT_DECLARATION,
   EXPRESSION = STATEMENT_EXPRESSION,
   NULL = STATEMENT_NULL,
   COMPOUND = STATEMENT_COMPOUND,
   IF = STATEMENT_IF,
   SWITCH = STATEMENT_SWITCH,
   CASE = STATEMENT_CASE,
   DEFAULT = STATEMENT_DEFAULT,
   WHILE = STATEMENT_WHILE,
   DO_WHILE = STATEMENT_DO_WHILE,
   FOR = STATEMENT_FOR,
   RETURN = STATEMENT_RETURN,
   BREAK = STATEMENT_BREAK,
   CONTINUE = STATEMENT_CONTINUE,
   GOTO = STATEMENT_GOTO,
   LABEL = STATEMENT_LABEL,
}

local DeclarationKind = {
   VARIABLE = DECLARATION_VARIABLE,
   FUNCTION = DECLARATION_FUNCTION,
   TYPEDEF = DECLARATION_TYPEDEF,
   TAG = DECLARATION_TAG,
}

local InitializerKind = {
   EXPR = INIT_EXPR,
   LIST = INIT_LIST,
}

local DesignatorKind = {
   FIELD = DESIG_FIELD,
   INDEX = DESIG_INDEX,
}

local StorageClass = {
   TYPEDEF = STORAGE_TYPEDEF,
   EXTERN = STORAGE_EXTERN,
   STATIC = STORAGE_STATIC,
   AUTO = STORAGE_AUTO,
   REGISTER = STORAGE_REGISTER,
}

local FunctionSpecifier = {
   INLINE = FUNC_INLINE,
}

local TagKind = {
   STRUCT = TAG_STRUCT,
   UNION = TAG_UNION,
}

local DerivedDeclaratorKind = {
   POINTER = DERIVED_POINTER,
   ARRAY = DERIVED_ARRAY,
   FUNCTION = DERIVED_FUNCTION,
}

local TypeSpecifierKind = {
   BUILTIN = TYPESPEC_BUILTIN,
   TYPEDEF = TYPESPEC_TYPEDEF,
   STRUCT = TYPESPEC_STRUCT,
   ENUM = TYPESPEC_ENUM,
}

local macroexp valid_expr_kind(k: integer): boolean
   return (function(kind: integer): boolean
      return kind == EXPR_IDENTIFIER
         or kind == EXPR_NUMBER_LITERAL
         or kind == EXPR_STRING_LITERAL
         or kind == EXPR_CHAR_LITERAL
         or kind == EXPR_UNARY
         or kind == EXPR_BINARY
         or kind == EXPR_CONDITIONAL
         or kind == EXPR_ASSIGNMENT
         or kind == EXPR_CALL
         or kind == EXPR_INDEX
         or kind == EXPR_FIELD
         or kind == EXPR_CAST
         or kind == EXPR_SIZEOF
         or kind == EXPR_COMPOUND_LITERAL
   end)(k)
end

local macroexp valid_statement_kind(k: integer): boolean
   return (function(kind: integer): boolean
      return kind == STATEMENT_DECLARATION
         or kind == STATEMENT_EXPRESSION
         or kind == STATEMENT_NULL
         or kind == STATEMENT_COMPOUND
         or kind == STATEMENT_IF
         or kind == STATEMENT_SWITCH
         or kind == STATEMENT_CASE
         or kind == STATEMENT_DEFAULT
         or kind == STATEMENT_WHILE
         or kind == STATEMENT_DO_WHILE
         or kind == STATEMENT_FOR
         or kind == STATEMENT_RETURN
         or kind == STATEMENT_BREAK
         or kind == STATEMENT_CONTINUE
         or kind == STATEMENT_GOTO
         or kind == STATEMENT_LABEL
   end)(k)
end

local macroexp valid_declaration_kind(k: integer): boolean
   return (function(kind: integer): boolean
      return kind == DECLARATION_VARIABLE
         or kind == DECLARATION_FUNCTION
         or kind == DECLARATION_TYPEDEF
         or kind == DECLARATION_TAG
   end)(k)
end

local macroexp valid_initializer_kind(k: integer): boolean
   return (function(kind: integer): boolean return kind == INIT_EXPR or kind == INIT_LIST  end)(k)
end

local macroexp valid_designator_kind(k: integer): boolean
   return (function(kind: integer): boolean return kind == DESIG_FIELD or kind == DESIG_INDEX  end)(k)
end

local record SourceReference is ffi.CData where ffi.istype("struct SourceReference", self)
   file_id: integer
   source: TLStringView
end

local record SourcePointer is ffi.CData where ffi.istype("struct SourcePointer", self)
   file_id: integer
   ptr: ffi.CString
end

local interface Expr is ffi.CData where valid_expr_kind(self.kind)
   kind: integer
   span: Span
end

local record IdentifierExpr is Expr
   where self.kind == EXPR_IDENTIFIER

   name: TLToken
end

local record NumberLiteralExpr is Expr
   where self.kind == EXPR_NUMBER_LITERAL

   token: TLToken
end

local record StringLiteralExpr is Expr
   where self.kind == EXPR_STRING_LITERAL

   parts: ffi.Pointer<TLToken>
   parts_len: integer
end

local record CharLiteralExpr is Expr
   where self.kind == EXPR_CHAR_LITERAL

   token: TLToken
end

local record UnaryExpr is Expr
   where self.kind == EXPR_UNARY

   op: TLToken
   operand: ffi.Pointer<ExprNode>
   postfix: boolean
end

local record BinaryExpr is Expr
   where self.kind == EXPR_BINARY

   op: TLToken
   lhs: ffi.Pointer<ExprNode>
   rhs: ffi.Pointer<ExprNode>
end

local record ConditionalExpr is Expr
   where self.kind == EXPR_CONDITIONAL

   cond: ffi.Pointer<ExprNode>
   then_expr: ffi.Pointer<ExprNode>
   else_expr: ffi.Pointer<ExprNode>
end

local record AssignmentExpr is Expr
   where self.kind == EXPR_ASSIGNMENT

   op: TLToken
   lhs: ffi.Pointer<ExprNode>
   rhs: ffi.Pointer<ExprNode>
end

local record CallExpr is Expr
   where self.kind == EXPR_CALL

   callee: ffi.Pointer<ExprNode>
   args: ffi.Pointer<ffi.Pointer<ExprNode>>
   args_len: integer
end

local record IndexExpr is Expr
   where self.kind == EXPR_INDEX

   array: ffi.Pointer<ExprNode>
   index: ffi.Pointer<ExprNode>
end

local record FieldExpr is Expr
   where self.kind == EXPR_FIELD

   receiver: ffi.Pointer<ExprNode>
   field: TLToken
   is_arrow: boolean
end

local record CastExpr is Expr
   where self.kind == EXPR_CAST

   type_name: ffi.Pointer<TypeName>
   value: ffi.Pointer<ExprNode>
end

local record SizeofExpr is Expr
   where self.kind == EXPR_SIZEOF

   type_name: ffi.Pointer<TypeName>
   expr: ffi.Pointer<ExprNode>
end

local record CompoundLiteralExpr is Expr
   where self.kind == EXPR_COMPOUND_LITERAL

   type_name: ffi.Pointer<TypeName>
   init: ffi.Pointer<Initializer>
end

local type ExprNode = IdentifierExpr
   | NumberLiteralExpr
   | StringLiteralExpr
   | CharLiteralExpr
   | UnaryExpr
   | BinaryExpr
   | ConditionalExpr
   | AssignmentExpr
   | CallExpr
   | IndexExpr
   | FieldExpr
   | CastExpr
   | SizeofExpr
   | CompoundLiteralExpr

local interface Designator is ffi.CData where valid_designator_kind(self.kind)
   kind: integer
   span: Span
end

local record FieldDesignator is Designator
   where self.kind == DESIG_FIELD

   name: TLToken
end

local record IndexDesignator is Designator
   where self.kind == DESIG_INDEX

   index: ffi.Pointer<ExprNode>
end

local record InitializerEntry is ffi.CData where ffi.istype("struct InitializerEntry", self)
   designators: ffi.Pointer<ffi.Pointer<Designator>>
   designators_len: integer
   value: ffi.Pointer<Initializer>
   span: Span
end

local interface Initializer is ffi.CData where valid_initializer_kind(self.kind)
   kind: integer
   span: Span
end

local record ExpressionInitializer is Initializer
   where self.kind == INIT_EXPR

   expr: ffi.Pointer<ExprNode>
end

local record ListInitializer is Initializer
   where self.kind == INIT_LIST

   entries: ffi.Pointer<InitializerEntry>
   entries_len: integer
end

local record BuiltinTypeSpec is ffi.CData where self.kind == TYPESPEC_BUILTIN
   kind: integer
   span: Span
   builtin: ffi.Pointer<TypeNode>
end

local record TypedefTypeSpec is ffi.CData where self.kind == TYPESPEC_TYPEDEF
   kind: integer
   span: Span
   name: TLToken
end

local record StructDeclarator is ffi.CData where ffi.istype("struct StructDeclarator", self)
   span: Span
   declarator: ffi.Pointer<Declarator>
   bit_width: ffi.Pointer<ExprNode>
end

local record StructField is ffi.CData where ffi.istype("struct StructField", self)
   span: Span
   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarators: ffi.Pointer<StructDeclarator>
   declarators_len: integer
end

local record StructSpecifier is ffi.CData where self.kind == TYPESPEC_STRUCT
   kind: integer
   tag_kind: integer
   span: Span
   name: TLToken
   has_name: boolean
   fields: ffi.Pointer<StructField>
   fields_len: integer
   has_fields: boolean
end

local record Enumerator is ffi.CData where ffi.istype("struct Enumerator", self)
   name: TLToken
   value: ffi.Pointer<ExprNode>
   span: Span
end

local record EnumSpecifier is ffi.CData where self.kind == TYPESPEC_ENUM
   kind: integer
   span: Span
   name: TLToken
   has_name: boolean
   enumerators: ffi.Pointer<Enumerator>
   enumerators_len: integer
   has_enumerators: boolean
end

local type TypeSpecifier = BuiltinTypeSpec | TypedefTypeSpec | StructSpecifier | EnumSpecifier

local record DeclarationSpecifiers is ffi.CData where ffi.istype("struct DeclarationSpecifiers", self)
   storage: ffi.Pointer<integer>
   storage_len: integer
   func_specs: ffi.Pointer<integer>
   func_specs_len: integer
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
   type_spec: ffi.Pointer<TypeSpecifier>
   span: Span
end

local record PointerDeclarator is ffi.CData where self.kind == DERIVED_POINTER
   kind: integer
   span: Span
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
end

local record ArrayDeclarator is ffi.CData where self.kind == DERIVED_ARRAY
   kind: integer
   span: Span
   qualifiers_len: integer
   qualifiers: ffi.Array<integer>
   is_static: boolean
   is_vla: boolean
   size: ffi.Pointer<ExprNode>
end

local record FunctionDeclarator is ffi.CData where self.kind == DERIVED_FUNCTION
   kind: integer
   params: ffi.Pointer<Parameter>
   params_len: integer
   is_variadic: boolean
end

local type DerivedDeclarator = PointerDeclarator | ArrayDeclarator | FunctionDeclarator

local record Declarator is ffi.CData where ffi.istype("struct Declarator", self)
   name: TLToken
   has_name: boolean
   derived: ffi.Pointer<ffi.Pointer<DerivedDeclarator>>
   derived_len: integer
   span: Span
end

local record TypeName is ffi.CData where ffi.istype("struct TypeName", self)
   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarator: ffi.Pointer<Declarator>
   has_declarator: boolean
   type: ffi.Pointer<TypeNode>
   span: Span
end

local record Parameter is ffi.CData where ffi.istype("struct Parameter", self)
   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarator: ffi.Pointer<Declarator>
   has_declarator: boolean
   type: ffi.Pointer<TypeNode>
   span: Span
end

local interface Statement is ffi.CData where valid_statement_kind(self.kind)
   kind: integer
   span: Span
end

local record DeclarationStatement is Statement
   where self.kind == STATEMENT_DECLARATION

   decls: ffi.Pointer<ffi.Pointer<DeclarationNode>>
   decls_len: integer
end

local record ExpressionStatement is Statement
   where self.kind == STATEMENT_EXPRESSION

   expr: ffi.Pointer<ExprNode>
end

local record NullStatement is Statement
   where self.kind == STATEMENT_NULL
end

local record CompoundStatement is Statement
   where self.kind == STATEMENT_COMPOUND

   items: ffi.Pointer<ffi.Pointer<StatementNode>>
   items_len: integer
end

local record IfStatement is Statement
   where self.kind == STATEMENT_IF

   cond: ffi.Pointer<ExprNode>
   then_branch: ffi.Pointer<StatementNode>
   else_branch: ffi.Pointer<StatementNode>
end

local record SwitchStatement is Statement
   where self.kind == STATEMENT_SWITCH

   expr: ffi.Pointer<ExprNode>
   body: ffi.Pointer<StatementNode>
end

local record CaseStatement is Statement
   where self.kind == STATEMENT_CASE

   expr: ffi.Pointer<ExprNode>
   body: ffi.Pointer<StatementNode>
end

local record DefaultStatement is Statement
   where self.kind == STATEMENT_DEFAULT

   body: ffi.Pointer<StatementNode>
end

local record WhileStatement is Statement
   where self.kind == STATEMENT_WHILE

   cond: ffi.Pointer<ExprNode>
   body: ffi.Pointer<StatementNode>
end

local record DoWhileStatement is Statement
   where self.kind == STATEMENT_DO_WHILE

   body: ffi.Pointer<StatementNode>
   cond: ffi.Pointer<ExprNode>
end

local record ForStatement is Statement
   where self.kind == STATEMENT_FOR

   init: ffi.Pointer<StatementNode>
   cond: ffi.Pointer<ExprNode>
   step: ffi.Pointer<ExprNode>
   body: ffi.Pointer<StatementNode>
end

local record ReturnStatement is Statement
   where self.kind == STATEMENT_RETURN

   value: ffi.Pointer<ExprNode>
end

local record BreakStatement is Statement
   where self.kind == STATEMENT_BREAK
end

local record ContinueStatement is Statement
   where self.kind == STATEMENT_CONTINUE
end

local record GotoStatement is Statement
   where self.kind == STATEMENT_GOTO

   name: TLToken
end

local record LabelStatement is Statement
   where self.kind == STATEMENT_LABEL

   name: TLToken
   body: ffi.Pointer<StatementNode>
end

local type StatementNode = DeclarationStatement
   | ExpressionStatement
   | NullStatement
   | CompoundStatement
   | IfStatement
   | SwitchStatement
   | CaseStatement
   | DefaultStatement
   | WhileStatement
   | DoWhileStatement
   | ForStatement
   | ReturnStatement
   | BreakStatement
   | ContinueStatement
   | GotoStatement
   | LabelStatement

local interface Declaration is ffi.CData where valid_declaration_kind(self.kind)
   kind: integer
   span: Span
end

local record VariableDeclaration is Declaration
   where self.kind == DECLARATION_VARIABLE

   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarator: ffi.Pointer<Declarator>
   type: ffi.Pointer<TypeNode>
   init: ffi.Pointer<Initializer>
end

local record FunctionDeclaration is Declaration
   where self.kind == DECLARATION_FUNCTION

   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarator: ffi.Pointer<Declarator>
   type: ffi.Pointer<TypeNode>
   body: ffi.Pointer<StatementNode>
   old_param_decls: ffi.Pointer<ffi.Pointer<DeclarationNode>>
   old_param_decls_len: integer
end

local record TypedefDeclaration is Declaration
   where self.kind == DECLARATION_TYPEDEF

   specifiers: ffi.Pointer<DeclarationSpecifiers>
   declarator: ffi.Pointer<Declarator>
   type: ffi.Pointer<TypeNode>
end

local record TagDeclaration is Declaration
   where self.kind == DECLARATION_TAG

   specifiers: ffi.Pointer<DeclarationSpecifiers>
   type: ffi.Pointer<TypeNode>
end

local type DeclarationNode = VariableDeclaration | FunctionDeclaration | TypedefDeclaration | TagDeclaration

local record TranslationUnit is ffi.CData where ffi.istype("struct TranslationUnit", self)
   src_ptr: ffi.CString
   src_refs: ffi.Pointer<SourceReference>
   src_refs_len: integer
   src_ptrs: ffi.Pointer<SourcePointer>
   src_ptrs_len: integer
   decls: ffi.Pointer<ffi.Pointer<DeclarationNode>>
   decls_len: integer
end

return {
   ExprKind = ExprKind,
   StatementKind = StatementKind,
   DeclarationKind = DeclarationKind,
   InitializerKind = InitializerKind,
   DesignatorKind = DesignatorKind,
   StorageClass = StorageClass,
   FunctionSpecifier = FunctionSpecifier,
   TypeSpecifierKind = TypeSpecifierKind,
   DerivedDeclaratorKind = DerivedDeclaratorKind,
   TagKind = TagKind,
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
   DeclarationSpecifiers = DeclarationSpecifiers,
   PointerDeclarator = PointerDeclarator,
   ArrayDeclarator = ArrayDeclarator,
   FunctionDeclarator = FunctionDeclarator,
   DerivedDeclarator = DerivedDeclarator,
   Declarator = Declarator,
   TypeName = TypeName,
   Parameter = Parameter,
   Statement = Statement,
   StatementNode = StatementNode,
   DeclarationStatement = DeclarationStatement,
   ExpressionStatement = ExpressionStatement,
   NullStatement = NullStatement,
   CompoundStatement = CompoundStatement,
   IfStatement = IfStatement,
   SwitchStatement = SwitchStatement,
   CaseStatement = CaseStatement,
   DefaultStatement = DefaultStatement,
   WhileStatement = WhileStatement,
   DoWhileStatement = DoWhileStatement,
   ForStatement = ForStatement,
   ReturnStatement = ReturnStatement,
   BreakStatement = BreakStatement,
   ContinueStatement = ContinueStatement,
   GotoStatement = GotoStatement,
   LabelStatement = LabelStatement,
   Declaration = Declaration,
   DeclarationNode = DeclarationNode,
   VariableDeclaration = VariableDeclaration,
   FunctionDeclaration = FunctionDeclaration,
   TypedefDeclaration = TypedefDeclaration,
   TagDeclaration = TagDeclaration,
   TranslationUnit = TranslationUnit,
   SourceReference = SourceReference,
   SourcePointer = SourcePointer,
}
