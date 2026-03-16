/// Jet AST types - represents the parsed structure of Jet source code.

pub type Module {
  Module(name: String, line: Int, body: List(TopLevel))
}

pub type TopLevel {
  // Module/class declaration (emitted as first item in module)
  ModuleDecl(name: String, line: Int)
  ClassDecl(name: String, line: Int)

  // Function definitions
  FuncDef(
    name: String,
    line: Int,
    args: List(Expr),
    guards: List(Expr),
    body: List(Expr),
    context: FuncContext,
  )

  // Decorated function: attribute + function def
  DecoratedFunc(attr: TopLevel, func: TopLevel)

  // Class definition with methods
  ClassDef(name: String, line: Int, methods: List(TopLevel), is_actor: Bool)

  // Attributes
  Attribute(name: String, line: Int, args: List(Expr))

  // Export
  ExportDecl(line: Int, names: List(Expr))
  ExportAllDecl(line: Int)

  // Behavior
  BehaviorDecl(name: String, line: Int)

  // Record definition
  RecordDef(name: String, line: Int, fields: List(Expr))

  // Patterns definition
  PatternsDef(name: String, line: Int, members: List(Expr))

  // Needs declaration (effect dependency)
  NeedsDecl(name: String, line: Int)

  // Platform definition (effect boundary)
  PlatformDef(name: String, line: Int, providers: List(ProvideClause))

  // Using clause on function (test effect override)
  UsingFunc(
    func: TopLevel,
    overrides: List(UsingOverride),
  )

  // Expose declaration (actor public interface)
  ExposeDecl(methods: List(ExposedMethod), line: Int)

  // Peers declaration (actor dependencies)
  PeersDecl(peers: List(PeerDef), line: Int)
}

/// A provide clause inside a platform block: `provide IO with StandardIO`
pub type ProvideClause {
  ProvideClause(need: String, implementation: String, line: Int)
}

/// A using override on a function: `using MockIO for IO`
pub type UsingOverride {
  UsingOverride(mock: String, need: String, line: Int)
}

/// An exposed method: `method_name()`  (arity inferred from param count)
pub type ExposedMethod {
  ExposedMethod(name: String, arity: Int, line: Int)
}

/// A peer dependency: `counter: Counter`
pub type PeerDef {
  PeerDef(name: String, actor_type: String, line: Int)
}

pub type FuncContext {
  InstanceMethod
  ActorInstanceMethod
  ClassMethod
  ModuleMethod
  BlockLambda
  GuardContext
}

pub type Expr {
  // Literals
  IntLit(value: Int, line: Int)
  FloatLit(value: Float, line: Int)
  StrLit(value: String, line: Int)
  AtomLit(value: String, line: Int)
  BoolLit(value: Bool, line: Int)
  NilLit(line: Int)

  // Variables
  Var(name: String, line: Int)

  // Instance attribute reference: @name
  RefAttr(name: String, line: Int)

  // Collections
  ListLit(elems: List(Expr), line: Int)
  Cons(head: Expr, tail: Expr, line: Int)
  TupleLit(elems: List(Expr), line: Int)
  MapExpr(fields: List(Expr), line: Int)
  MapField(key: Expr, value: Expr, line: Int)
  MapFieldAtom(key: String, value: Expr, line: Int)

  // Binary
  BinaryLit(fields: List(Expr), line: Int)
  BinaryField1(value: Expr)
  BinaryField2(value: Expr, types: List(Expr))
  BinaryFieldSize(value: Expr, size: Expr, types_or_default: BinaryDefault)
  BinaryFieldSizeTypes(value: Expr, size: Expr, types: List(Expr))

  // Binary operations
  BinOp(op: BinOperator, left: Expr, right: Expr, line: Int)

  // Unary operations
  UnaryOp(op: UnaryOperator, operand: Expr, line: Int)

  // Assignment
  Assign(pattern: Expr, value: Expr, line: Int)

  // Method call: obj.method(args)
  MethodCall(object: Expr, method: String, args: List(Expr), line: Int)

  // Function application
  Apply(func: Expr, args: List(Expr), line: Int)
  ApplyName(func: Expr, args: List(Expr), line: Int)

  // Function references
  FuncRef1(module: String, func: String, line: Int)
  FuncRef0(name: String, line: Int)
  FuncRefStr(module: String, func: String, line: Int)
  FuncRefTuple(tuple_expr: Expr, func: String, line: Int)
  FuncRefExpr(expr: Expr)

  // Get function: &Module.func/arity
  GetFunc2(module: String, func: String, arity: Expr, line: Int)
  GetFunc1(func: String, arity: Expr, line: Int)

  // Control flow
  IfExpr(
    condition: Expr,
    then_body: List(Expr),
    else_body: List(Expr),
    line: Int,
  )
  ElsifExpr(
    condition: Expr,
    then_body: List(Expr),
    else_body: List(Expr),
    line: Int,
  )
  MatchExpr(value: Expr, clauses: List(Expr), line: Int)
  CaseClause(patterns: List(Expr), guards: List(Expr), body: List(Expr))
  ReceiveExpr(clauses: List(Expr), line: Int)
  ReceiveAfterExpr(
    clauses: List(Expr),
    timeout: Expr,
    actions: List(Expr),
    line: Int,
  )

  // Lambda
  Lambda(args: List(Expr), guards: List(Expr), body: List(Expr), line: Int)

  // Comprehensions
  ListComp(template: Expr, generators: List(Expr), guard: List(Expr), line: Int)
  BinaryComp(
    template: Expr,
    generators: List(Expr),
    guard: List(Expr),
    line: Int,
  )
  ListGenerator(pattern: Expr, body: Expr, line: Int)
  BinaryGenerator(pattern: Expr, body: Expr, line: Int)

  // Record expressions
  RecordExpr(name: String, fields: List(Expr), line: Int)
  RecordField1(name: String, line: Int)
  RecordField2(name: String, value: Expr, line: Int)
  RecordFieldIndex(record: String, field: String, line: Int)

  // Special operators
  Range(from: Expr, to: Expr, line: Int)
  ColonColonAccess(map: Expr, key: String, line: Int)
  PipeOp(left: Expr, right: Expr, line: Int)
  Send(receiver: Expr, message: Expr, line: Int)

  // Catch
  CatchExpr(expr: Expr, line: Int)

  // Fun name/arity for exports
  FunName(name: String, arity: Int, line: Int)
}

pub type BinOperator {
  OpPlus
  OpMinus
  OpTimes
  OpDiv
  OpFloorDiv
  OpPow
  OpPercent
  OpAppend
  OpEqEq
  OpBangEq
  OpLt
  OpGt
  OpLtEq
  OpGtEq
  OpAnd
  OpOr
  OpXor
  OpBand
  OpBor
  OpBxor
  OpBsl
  OpBsr
}

pub type UnaryOperator {
  OpNot
  OpBnot
  OpNeg
}

pub type BinaryDefault {
  DefaultTypes
  CustomTypes(List(Expr))
}
