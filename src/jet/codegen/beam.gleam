import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/set.{type Set}
import gleam/string
import jet/ast
import jet/error

/// Opaque type representing an Erlang syntax tree node
pub type ErlSyntax

/// Opaque type for Erlang dynamic values from FFI
pub type ErlDynamic

/// Compilation result: module atom name and binary
pub type CompileResult =
  Result(#(ErlDynamic, BitArray), error.JetError)

/// Context for code generation
type Context {
  Context(
    module_name: String,
    context_stack: List(ast.FuncContext),
    func_map: Dict(#(String, Int), ErlSyntax),
    patterns: Dict(String, List(ast.Expr)),
    needs_names: Set(String),
  )
}

type Mode {
  ExprMode
  PatternMode
}

/// Check if a function name/arity matches a Kernel module function (def self.xxx).
/// These should be called directly as Kernel:func(args) rather than
/// routed through call_method, even inside instance methods.
fn is_kernel_module_func(name: String, arity: Int) -> Bool {
  case name, arity {
    "puts", 1 -> True
    "puts", 2 -> True
    "pid", 1 -> True
    "kill", 1 -> True
    "monitor", 1 -> True
    "demonitor", 1 -> True
    "link", 1 -> True
    "unlink", 1 -> True
    "trap_exit", 0 -> True
    "send_after", 2 -> True
    "send_after", 3 -> True
    "send_interval", 2 -> True
    "send_interval", 3 -> True
    "cancel_timer", 1 -> True
    "find", 1 -> True
    "find_global", 1 -> True
    // Erlang BIFs — direct call to Kernel wrappers
    // Note: is_* guard BIFs are NOT included here — they already work
    // correctly in guards (if is_list(x) ...) and adding them to Kernel
    // would shadow the guard BIFs, breaking guard expressions.
    "element", 2 -> True
    "length", 1 -> True
    "hd", 1 -> True
    "tl", 1 -> True
    "integer_to_list", 1 -> True
    "list_to_binary", 1 -> True
    "binary_to_list", 1 -> True
    "atom_to_list", 1 -> True
    "list_to_atom", 1 -> True
    "list_to_existing_atom", 1 -> True
    "float_to_list", 1 -> True
    "list_to_float", 1 -> True
    "list_to_integer", 1 -> True
    "list_to_tuple", 1 -> True
    "tuple_to_list", 1 -> True
    _, _ -> False
  }
}

// --- Public API ---

pub fn compile(module: ast.Module) -> CompileResult {
  // Collect needs declarations upfront
  let needs = collect_needs(module.body, set.new())

  let platforms = collect_platforms(module.body, [])
  validate_needs_platforms(needs, platforms, module.name)

  let ctx =
    Context(
      module_name: module.name,
      context_stack: [],
      func_map: dict.new(),
      patterns: dict.new(),
      needs_names: needs,
    )

  // First item is always the module declaration
  let module_attr =
    erl_attribute(erl_atom("module"), [
      erl_atom(module.name),
    ])
    |> erl_set_pos(module.line)

  // Process top-level statements
  case process_toplevel(module.body, ctx, []) {
    Ok(#(forms, ctx)) -> {
      let all_forms = [
        module_attr,
        ..list.append(forms, dict.values(ctx.func_map))
      ]
      case do_compile_forms(all_forms) {
        Ok(#(mod_atom, binary)) -> Ok(#(mod_atom, binary))
        Error(msg) -> Error(error.CodegenError(0, msg))
      }
    }
    Error(e) -> Error(e)
  }
}

// --- Top-level processing ---

fn collect_needs(body: List(ast.TopLevel), acc: Set(String)) -> Set(String) {
  case body {
    [] -> acc
    [ast.NeedsDecl(name, _), ..rest] ->
      collect_needs(rest, set.insert(acc, name))
    [_, ..rest] -> collect_needs(rest, acc)
  }
}

// --- Expose method existence check ---

fn validate_expose(class_name: String, methods: List(ast.TopLevel)) -> Nil {
  // Extract expose declarations
  let exposed = collect_exposed_methods(methods, [])
  // Extract actual method definitions (unmangle names)
  let defined = collect_defined_methods(class_name, methods, set.new())
  // Check each exposed method exists
  list.each(exposed, fn(em) {
    let key = em.name <> "/" <> int.to_string(em.arity)
    case set.contains(defined, key) {
      True -> Nil
      False ->
        io.println_error(
          "Warning: expose declares '"
          <> key
          <> "' but no such method exists in class "
          <> class_name,
        )
    }
  })
}

fn collect_exposed_methods(
  methods: List(ast.TopLevel),
  acc: List(ast.ExposedMethod),
) -> List(ast.ExposedMethod) {
  case methods {
    [] -> acc
    [ast.ExposeDecl(exposed, _), ..rest] ->
      collect_exposed_methods(rest, list.append(acc, exposed))
    [_, ..rest] -> collect_exposed_methods(rest, acc)
  }
}

fn collect_defined_methods(
  class_name: String,
  methods: List(ast.TopLevel),
  acc: Set(String),
) -> Set(String) {
  let instance_prefix = "_" <> class_name <> "_instance_method_"
  let class_prefix = "_" <> class_name <> "_class_method_"
  case methods {
    [] -> acc
    [ast.FuncDef(name, _, args, _, _, context), ..rest] -> {
      let key = case string.starts_with(name, instance_prefix) {
        True -> {
          let method_name = string.drop_start(name, string.length(instance_prefix))
          // Instance methods have self as first arg, subtract 1
          let arity = list.length(args) - 1
          method_name <> "/" <> int.to_string(arity)
        }
        False ->
          case string.starts_with(name, class_prefix) {
            True -> {
              let method_name = string.drop_start(name, string.length(class_prefix))
              let arity = case context {
                ast.ClassMethod -> list.length(args)
                _ -> list.length(args)
              }
              method_name <> "/" <> int.to_string(arity)
            }
            False -> ""
          }
      }
      case key {
        "" -> collect_defined_methods(class_name, rest, acc)
        _ -> collect_defined_methods(class_name, rest, set.insert(acc, key))
      }
    }
    [_, ..rest] -> collect_defined_methods(class_name, rest, acc)
  }
}

// --- Needs/Platform consistency check ---

fn collect_platforms(
  body: List(ast.TopLevel),
  acc: List(ast.TopLevel),
) -> List(ast.TopLevel) {
  case body {
    [] -> acc
    [ast.PlatformDef(_, _, _) as p, ..rest] ->
      collect_platforms(rest, [p, ..acc])
    [_, ..rest] -> collect_platforms(rest, acc)
  }
}

fn validate_needs_platforms(
  needs: Set(String),
  platforms: List(ast.TopLevel),
  _module_name: String,
) -> Nil {
  // Only validate if there are platforms in this module
  case platforms {
    [] -> Nil
    _ -> {
      // Collect all provided need names across all platforms
      let all_provided = collect_all_provided(platforms, set.new())

      // Check: platform provides X but no needs X declared
      list.each(platforms, fn(platform) {
        case platform {
          ast.PlatformDef(pname, _, providers) ->
            list.each(providers, fn(p) {
              case set.contains(needs, p.need) {
                True -> Nil
                False ->
                  io.println_error(
                    "Warning: platform '"
                    <> pname
                    <> "' provides '"
                    <> p.need
                    <> "' but no 'needs "
                    <> p.need
                    <> "' is declared",
                  )
              }
            })
          _ -> Nil
        }
      })

      // Check: needs X declared but no platform provides it
      set.to_list(needs)
      |> list.each(fn(need_name) {
        case set.contains(all_provided, need_name) {
          True -> Nil
          False ->
            io.println_error(
              "Note: 'needs "
              <> need_name
              <> "' is declared but no platform in this module provides it",
            )
        }
      })
    }
  }
}

fn collect_all_provided(
  platforms: List(ast.TopLevel),
  acc: Set(String),
) -> Set(String) {
  case platforms {
    [] -> acc
    [ast.PlatformDef(_, _, providers), ..rest] -> {
      let provided =
        list.fold(providers, acc, fn(s, p) { set.insert(s, p.need) })
      collect_all_provided(rest, provided)
    }
    [_, ..rest] -> collect_all_provided(rest, acc)
  }
}

// --- Peers getter method generation ---

fn generate_peers_getters(
  class_name: String,
  methods: List(ast.TopLevel),
) -> List(ast.TopLevel) {
  let peer_getters = collect_peer_getters(class_name, methods, [])
  list.append(methods, peer_getters)
}

fn collect_peer_getters(
  class_name: String,
  methods: List(ast.TopLevel),
  acc: List(ast.TopLevel),
) -> List(ast.TopLevel) {
  case methods {
    [] -> acc
    [ast.PeersDecl(peers, _), ..rest] -> {
      let getters =
        list.map(peers, fn(peer) {
          ast.FuncDef(
            name: "_" <> class_name <> "_instance_method_" <> peer.name,
            line: peer.line,
            args: [ast.Var("self", 0)],
            guards: [],
            body: [
              ast.AtomLit(peer.name, 0),
            ],
            context: ast.ActorInstanceMethod,
          )
        })
      collect_peer_getters(class_name, rest, list.append(acc, getters))
    }
    [_, ..rest] -> collect_peer_getters(class_name, rest, acc)
  }
}

// --- Actor module function auto-generation ---

/// Check if a class has `meta Actor`
fn is_meta_actor(class_name: String, methods: List(ast.TopLevel)) -> Bool {
  let meta_key = "_" <> class_name <> "_meta"
  list.any(methods, fn(m) {
    case m {
      ast.Attribute(name, _, args) ->
        name == meta_key
        && list.any(args, fn(a) {
          case a {
            ast.AtomLit("Actor", _) -> True
            _ -> False
          }
        })
      _ -> False
    }
  })
}

/// Find the arity of the initialize method (excluding self)
fn find_initialize_arity(
  class_name: String,
  methods: List(ast.TopLevel),
) -> Int {
  let init_prefix = "_" <> class_name <> "_instance_method_initialize"
  let result =
    list.find(methods, fn(m) {
      case m {
        ast.FuncDef(name, _, _, _, _, _) -> name == init_prefix
        _ -> False
      }
    })
  case result {
    Ok(ast.FuncDef(_, _, args, _, _, _)) ->
      // args includes self, so subtract 1
      list.length(args) - 1
    _ -> 0
  }
}

/// Generate module-level functions for a meta Actor class:
/// - start_link_classname(args...) for Supervisor
/// - classname() accessor via whereis
fn generate_actor_module_funcs(
  module_name: String,
  class_name: String,
  init_arity: Int,
  line: Int,
) -> List(ast.TopLevel) {
  let lower_name = string.lowercase(class_name)

  // Generate arg names: arg1, arg2, ...
  let arg_names = {
    let indices = list.range(1, init_arity)
    list.map(indices, fn(i) { "arg" <> int.to_string(i) })
  }
  let arg_vars = list.map(arg_names, fn(n) { ast.Var(n, 0) })

  // start_link_classname(arg1, arg2, ...) ->
  //   gen_server:start_link({local, classname}, jet_runtime,
  //     [[arg1, arg2, ...], jet_runtime:class_def(Module, Class)], [])
  let start_link_func = ast.FuncDef(
    name: "start_link_" <> lower_name,
    line: line,
    args: arg_vars,
    guards: [],
    body: [
      ast.Apply(
        func: ast.FuncRef1("gen_server", "start_link", 0),
        args: [
          ast.TupleLit(
            elems: [ast.AtomLit("local", 0), ast.AtomLit(lower_name, 0)],
            line: 0,
          ),
          ast.AtomLit("jet_runtime", 0),
          ast.ListLit(
            elems: [
              ast.ListLit(elems: arg_vars, line: 0),
              ast.Apply(
                func: ast.FuncRef1("jet_runtime", "class_def", 0),
                args: [
                  ast.AtomLit(module_name, 0),
                  ast.AtomLit(class_name, 0),
                ],
                line: 0,
              ),
            ],
            line: 0,
          ),
          ast.ListLit(elems: [], line: 0),
        ],
        line: 0,
      ),
    ],
    context: ast.ModuleMethod,
  )

  // classname() -> erlang:whereis(classname)
  let accessor_func = ast.FuncDef(
    name: lower_name,
    line: line,
    args: [],
    guards: [],
    body: [
      ast.Apply(
        func: ast.FuncRef1("erlang", "whereis", 0),
        args: [ast.AtomLit(lower_name, 0)],
        line: 0,
      ),
    ],
    context: ast.ModuleMethod,
  )

  // child_spec_classname(arg1, arg2, ...) ->
  //   {classname, {Module, start_link_classname, [arg1, ...]}, permanent, 5000, worker, [Module]}
  let child_spec_func = ast.FuncDef(
    name: "child_spec_" <> lower_name,
    line: line,
    args: arg_vars,
    guards: [],
    body: [
      ast.TupleLit(
        elems: [
          ast.AtomLit(lower_name, 0),
          ast.TupleLit(
            elems: [
              ast.AtomLit(module_name, 0),
              ast.AtomLit("start_link_" <> lower_name, 0),
              ast.ListLit(elems: arg_vars, line: 0),
            ],
            line: 0,
          ),
          ast.AtomLit("permanent", 0),
          ast.IntLit(5000, 0),
          ast.AtomLit("worker", 0),
          ast.ListLit(
            elems: [ast.AtomLit(module_name, 0)],
            line: 0,
          ),
        ],
        line: 0,
      ),
    ],
    context: ast.ModuleMethod,
  )

  [start_link_func, accessor_func, child_spec_func]
}

fn process_toplevel(
  stmts: List(ast.TopLevel),
  ctx: Context,
  acc: List(ErlSyntax),
) -> Result(#(List(ErlSyntax), Context), error.JetError) {
  case stmts {
    [] -> Ok(#(list.reverse(acc), ctx))
    [stmt, ..rest] ->
      case stmt {
        ast.DecoratedFunc(attr, func_def) -> {
          let attr_form = toplevel_to_erl(attr, ctx)
          case func_def {
            ast.FuncDef(_name, _, _args, _, _, _) -> {
              let ctx = put_func(func_def, ctx)
              process_toplevel(rest, ctx, [attr_form, ..acc])
            }
            ast.UsingFunc(inner_func, overrides) -> {
              let wrapped = wrap_func_with_overrides(inner_func, overrides)
              let ctx = put_func(wrapped, ctx)
              process_toplevel(rest, ctx, [attr_form, ..acc])
            }
            _ -> process_toplevel(rest, ctx, [attr_form, ..acc])
          }
        }
        ast.FuncDef(_, _, _, _, _, _) -> {
          let ctx = put_func(stmt, ctx)
          process_toplevel(rest, ctx, acc)
        }
        ast.ClassDef(name, line, methods, is_actor) -> {
          validate_expose(name, methods)
          let methods = generate_peers_getters(name, methods)

          // Expand class into: a function returning new_class + mangled methods
          let class_func = ast.FuncDef(
            name: name,
            line: line,
            args: [],
            guards: [],
            body: [
              ast.Apply(
                func: ast.FuncRef1(
                  module: "jet_runtime",
                  func: "new_class",
                  line: 0,
                ),
                args: [
                  ast.AtomLit(value: ctx.module_name, line: 0),
                  ast.AtomLit(value: name, line: line),
                ],
                line: 0,
              ),
            ],
            context: ast.ModuleMethod,
          )
          // Auto-generate start_link and accessor for meta Actor classes
          let is_actor = is_actor || is_meta_actor(name, methods)
          let actor_funcs = case is_actor {
            True ->
              generate_actor_module_funcs(
                ctx.module_name,
                name,
                find_initialize_arity(name, methods),
                line,
              )
            False -> []
          }
          // For actor keyword, inject the meta attribute so jet_runtime recognizes it
          let methods = case is_actor && !is_meta_actor(name, methods) {
            True -> {
              let meta_attr = ast.Attribute(
                name: "_" <> name <> "_meta",
                line: line,
                args: [ast.AtomLit("Actor", line)],
              )
              [meta_attr, ..methods]
            }
            False -> methods
          }
          let expanded = [class_func, ..list.append(methods, actor_funcs)]
          process_toplevel(list.append(expanded, rest), ctx, acc)
        }
        ast.PatternsDef(name, _, members) -> {
          let ctx =
            Context(
              ..ctx,
              patterns: dict.insert(ctx.patterns, name, members),
            )
          process_toplevel(rest, ctx, acc)
        }
        ast.PlatformDef(name, line, providers) -> {
          // Generate a function that returns the provider map
          let platform_func = build_platform_func(name, line, providers)
          let ctx = put_func(platform_func, ctx)
          // Generate an activate function
          let activate_func = build_activate_func(name, line)
          let ctx = put_func(activate_func, ctx)
          process_toplevel(rest, ctx, acc)
        }
        ast.UsingFunc(func_def, overrides) -> {
          // Wrap function body with override setup/teardown
          let wrapped = wrap_func_with_overrides(func_def, overrides)
          let ctx = put_func(wrapped, ctx)
          process_toplevel(rest, ctx, acc)
        }
        _ -> {
          let form = toplevel_to_erl(stmt, ctx)
          process_toplevel(rest, ctx, [form, ..acc])
        }
      }
  }
}

// --- Function clause merging ---

fn put_func(func_def: ast.TopLevel, ctx: Context) -> Context {
  let func_syntax = func_to_erl(func_def, ctx)
  let name = erl_function_name_str(func_syntax)
  let arity = erl_function_arity_int(func_syntax)
  let key = #(name, arity)
  case dict.get(ctx.func_map, key) {
    Ok(prev) -> {
      let prev_clauses = erl_function_clauses(prev)
      let new_clauses = erl_function_clauses(func_syntax)
      let merged =
        erl_function(
          erl_function_name_node(func_syntax),
          list.append(prev_clauses, new_clauses),
        )
      Context(..ctx, func_map: dict.insert(ctx.func_map, key, merged))
    }
    Error(_) ->
      Context(..ctx, func_map: dict.insert(ctx.func_map, key, func_syntax))
  }
}

// --- TopLevel to Erlang syntax ---

fn toplevel_to_erl(stmt: ast.TopLevel, ctx: Context) -> ErlSyntax {
  case stmt {
    ast.ModuleDecl(name, line) ->
      erl_attribute(erl_atom("module"), [erl_atom(name)])
      |> erl_set_pos(line)

    ast.ExportAllDecl(line) ->
      erl_attribute(erl_atom("compile"), [erl_atom("export_all")])
      |> erl_set_pos(line)

    ast.ExportDecl(line, names) ->
      erl_attribute(erl_atom("export"), [
        erl_list(list.map(names, fn(n) { expr_to_erl(n, ctx, ExprMode) })),
      ])
      |> erl_set_pos(line)

    ast.BehaviorDecl(name, line) ->
      erl_attribute(erl_atom("behaviour"), [erl_atom(name)])
      |> erl_set_pos(line)

    ast.Attribute(name, line, args) ->
      erl_attribute(erl_atom(name) |> erl_set_pos(line), [
        erl_list(list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) })),
      ])
      |> erl_set_pos(line)

    ast.RecordDef(name, line, fields) ->
      erl_attribute(erl_atom("record") |> erl_set_pos(line), [
        erl_atom(name) |> erl_set_pos(line),
        erl_tuple(list.map(fields, fn(f) { expr_to_erl(f, ctx, ExprMode) })),
      ])
      |> erl_set_pos(line)

    ast.NeedsDecl(name, line) ->
      erl_attribute(erl_atom("needs") |> erl_set_pos(line), [
        erl_atom(name) |> erl_set_pos(line),
      ])
      |> erl_set_pos(line)

    ast.ExposeDecl(methods, line) ->
      erl_attribute(erl_atom("expose") |> erl_set_pos(line), [
        erl_list(
          list.map(methods, fn(m) {
            erl_tuple([
              erl_atom(m.name) |> erl_set_pos(m.line),
              erl_integer(m.arity) |> erl_set_pos(m.line),
            ])
          }),
        )
        |> erl_set_pos(line),
      ])
      |> erl_set_pos(line)

    ast.PeersDecl(peers, line) ->
      erl_attribute(erl_atom("peers") |> erl_set_pos(line), [
        erl_list(
          list.map(peers, fn(p) {
            erl_tuple([
              erl_atom(p.name) |> erl_set_pos(p.line),
              erl_atom(p.actor_type) |> erl_set_pos(p.line),
            ])
          }),
        )
        |> erl_set_pos(line),
      ])
      |> erl_set_pos(line)

    _ -> erl_atom("undefined")
  }
}

// --- Platform/Using helpers ---

/// Build a function that returns the provider map for a platform.
/// platform Production
///   provide IO with StandardIO
/// end
/// →
/// 'Production'() -> #{'IO' => 'StandardIO'}.
fn build_platform_func(
  name: String,
  line: Int,
  providers: List(ast.ProvideClause),
) -> ast.TopLevel {
  let map_fields =
    list.map(providers, fn(p) {
      ast.MapField(
        key: ast.AtomLit(value: p.need, line: p.line),
        value: ast.AtomLit(value: p.implementation, line: p.line),
        line: p.line,
      )
    })
  ast.FuncDef(
    name: name,
    line: line,
    args: [],
    guards: [],
    body: [ast.MapExpr(fields: map_fields, line: line)],
    context: ast.ModuleMethod,
  )
}

/// Build an activate function that sets the platform in process dict.
/// activate_Production() -> jet_platform_ffi:activate_platform(Production()).
fn build_activate_func(name: String, line: Int) -> ast.TopLevel {
  ast.FuncDef(
    name: "activate_" <> name,
    line: line,
    args: [],
    guards: [],
    body: [
      ast.Apply(
        func: ast.FuncRef1(
          module: "jet_platform_ffi",
          func: "activate_platform",
          line: line,
        ),
        args: [
          ast.ApplyName(
            func: ast.FuncRef0(name: name, line: line),
            args: [],
            line: line,
          ),
        ],
        line: line,
      ),
    ],
    context: ast.ModuleMethod,
  )
}

/// Wrap a function def with using overrides.
/// def foo() using MockIO for IO → function body wrapped with with_overrides
fn wrap_func_with_overrides(
  func_def: ast.TopLevel,
  overrides: List(ast.UsingOverride),
) -> ast.TopLevel {
  case func_def {
    ast.FuncDef(name, line, args, guards, body, context) -> {
      let override_map_fields =
        list.map(overrides, fn(o) {
          ast.MapField(
            key: ast.AtomLit(value: o.need, line: o.line),
            value: ast.AtomLit(value: o.mock, line: o.line),
            line: o.line,
          )
        })
      let override_map = ast.MapExpr(fields: override_map_fields, line: line)
      let lambda =
        ast.Lambda(args: [], guards: [], body: body, line: line)
      let wrapped_body = [
        ast.Apply(
          func: ast.FuncRef1(
            module: "jet_platform_ffi",
            func: "with_overrides",
            line: line,
          ),
          args: [override_map, lambda],
          line: line,
        ),
      ]
      ast.FuncDef(name, line, args, guards, wrapped_body, context)
    }
    _ -> func_def
  }
}

// --- Function definition to Erlang syntax ---

fn func_to_erl(func_def: ast.TopLevel, ctx: Context) -> ErlSyntax {
  case func_def {
    ast.FuncDef(name, line, args, guards, body, context) -> {
      let ctx =
        Context(..ctx, context_stack: [context, ..ctx.context_stack])
      let guard_ctx =
        Context(..ctx, context_stack: [ast.GuardContext, ..ctx.context_stack])
      let guard_forms =
        list.map(guards, fn(g) { expr_to_erl(g, guard_ctx, ExprMode) })
      let clause =
        make_clause(
          list.map(args, fn(a) { expr_to_erl(a, ctx, PatternMode) }),
          guard_forms,
          list.map(body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        )
        |> erl_set_pos(line)
      erl_function(erl_atom(name), [clause])
      |> erl_set_pos(line)
    }
    _ -> erl_atom("undefined")
  }
}

// --- Expression to Erlang syntax ---

fn expr_to_erl(expr: ast.Expr, ctx: Context, mode: Mode) -> ErlSyntax {
  case expr {
    // Literals
    ast.IntLit(value, line) -> erl_integer(value) |> erl_set_pos(line)
    ast.FloatLit(value, line) -> erl_float(value) |> erl_set_pos(line)
    ast.StrLit(value, line) -> erl_string(value) |> erl_set_pos(line)
    ast.AtomLit(value, line) -> erl_atom(value) |> erl_set_pos(line)
    ast.BoolLit(True, line) -> erl_atom("true") |> erl_set_pos(line)
    ast.BoolLit(False, line) -> erl_atom("false") |> erl_set_pos(line)
    ast.NilLit(line) -> erl_nil() |> erl_set_pos(line)

    // Variables — if name is a `needs` dependency, resolve at runtime
    ast.Var(name, line) ->
      case set.contains(ctx.needs_names, name) {
        True -> {
          let resolve_fn =
            erl_module_qualifier(
              erl_atom("jet_platform_ffi"),
              erl_atom("resolve_need"),
            )
          erl_application(resolve_fn, [erl_atom(name) |> erl_set_pos(line)])
          |> erl_set_pos(line)
        }
        False -> erl_variable(name) |> erl_set_pos(line)
      }

    // Instance attribute: @name -> maps:get(name, element(3, self))
    ast.RefAttr(name, line) -> {
      let maps_get = erl_module_qualifier(erl_atom("maps"), erl_atom("get"))
      let elem_fn =
        erl_module_qualifier(erl_atom("erlang"), erl_atom("element"))
      erl_application(maps_get, [
        erl_atom(name),
        erl_application(elem_fn, [
          erl_integer(3),
          erl_variable("self") |> erl_set_pos(line),
        ])
          |> erl_set_pos(line),
      ])
      |> erl_set_pos(line)
    }

    // Binary operators
    ast.BinOp(op, left, right, line) ->
      compile_binop(op, left, right, line, ctx, mode)

    // Unary operators
    ast.UnaryOp(ast.OpNot, operand, line) ->
      erl_prefix_expr(erl_operator("not"), expr_to_erl(operand, ctx, mode))
      |> erl_set_pos(line)
    ast.UnaryOp(ast.OpBnot, operand, line) ->
      erl_prefix_expr(erl_operator("bnot"), expr_to_erl(operand, ctx, mode))
      |> erl_set_pos(line)
    ast.UnaryOp(ast.OpNeg, operand, line) ->
      erl_prefix_expr(erl_operator("-"), expr_to_erl(operand, ctx, mode))
      |> erl_set_pos(line)

    // Assignment: pattern = expr
    // Note: @attr = expr is desugared by the rebind pass into
    //   self = setelement(3, self, maps:put(:attr, value, element(3, self)))
    ast.Assign(pattern, value, line) ->
      erl_match_expr(
        expr_to_erl(pattern, ctx, PatternMode),
        expr_to_erl(value, ctx, ExprMode),
      )
      |> erl_set_pos(line)

    // Method call: obj.method(args)
    ast.MethodCall(object, method, args, line) -> {
      let call_method =
        erl_module_qualifier(
          erl_atom("jet_runtime"),
          erl_atom("call_method"),
        )
      // If the receiver is a FuncRef (Module::func), call it first with no args
      let object_erl = case object {
        ast.FuncRef1(_, _, _) | ast.FuncRefStr(_, _, _) ->
          erl_application(
            expr_to_erl(object, ctx, ExprMode),
            [],
          )
          |> erl_set_pos(line)
        _ -> expr_to_erl(object, ctx, ExprMode)
      }
      erl_application(call_method, [
        object_erl,
        erl_atom(method),
        erl_list(list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) })),
      ])
      |> erl_set_pos(line)
    }

    // Function application: func(args)
    // If Module::func where Module is a needs name, use dynamic dispatch
    ast.Apply(ast.FuncRef1(module_name, func_name, _) as func, args, line) ->
      case set.contains(ctx.needs_names, module_name) {
        True -> {
          // erlang:apply(jet_platform_ffi:resolve_need(:Module), func, args)
          let resolve_fn =
            erl_module_qualifier(
              erl_atom("jet_platform_ffi"),
              erl_atom("resolve_need"),
            )
          let resolved_mod = erl_application(resolve_fn, [
            erl_atom(module_name) |> erl_set_pos(line),
          ])
          let apply_fn =
            erl_module_qualifier(erl_atom("erlang"), erl_atom("apply"))
          erl_application(apply_fn, [
            resolved_mod,
            erl_atom(func_name) |> erl_set_pos(line),
            erl_list(list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) })),
          ])
          |> erl_set_pos(line)
        }
        False -> {
          let op = expr_to_erl(func, ctx, ExprMode)
          erl_application(
            op,
            list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) }),
          )
          |> erl_set_pos(line)
        }
      }

    ast.Apply(func, args, line) -> {
      let op = expr_to_erl(func, ctx, ExprMode)
      erl_application(
        op,
        list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) }),
      )
      |> erl_set_pos(line)
    }

    // Named function application: name(args) - context-dependent
    ast.ApplyName(func, args, line) -> {
      let current_ctx = case ctx.context_stack {
        [c, ..] -> c
        [] -> ast.ModuleMethod
      }
      case current_ctx {
        ast.InstanceMethod | ast.ActorInstanceMethod -> {
          // In instance context, route through call_method
          let method_name = case func {
            ast.FuncRef0(name, _) -> name
            ast.FuncRef1(_, func_name, _) -> func_name
            _ -> "unknown"
          }
          let erl_args =
            list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) })
          case is_kernel_module_func(method_name, list.length(args)) {
            True -> {
              // Kernel module function: call directly as Kernel:func(args)
              let kernel_func =
                erl_module_qualifier(
                  erl_atom("Kernel"),
                  erl_atom(method_name),
                )
              erl_application(kernel_func, erl_args)
              |> erl_set_pos(line)
            }
            False -> {
              let call_method =
                erl_module_qualifier(
                  erl_atom("jet_runtime"),
                  erl_atom("call_method"),
                )
              erl_application(call_method, [
                erl_variable("self"),
                erl_atom(method_name),
                erl_list(erl_args),
              ])
              |> erl_set_pos(line)
            }
          }
        }
        _ -> {
          let method_name = case func {
            ast.FuncRef0(name, _) -> name
            _ -> ""
          }
          let erl_args =
            list.map(args, fn(a) { expr_to_erl(a, ctx, ExprMode) })
          case is_kernel_module_func(method_name, list.length(args)) {
            True -> {
              let kernel_func =
                erl_module_qualifier(
                  erl_atom("Kernel"),
                  erl_atom(method_name),
                )
              erl_application(kernel_func, erl_args)
              |> erl_set_pos(line)
            }
            False -> {
              let op = expr_to_erl(func, ctx, ExprMode)
              erl_application(op, erl_args)
              |> erl_set_pos(line)
            }
          }
        }
      }
    }

    // Function references
    ast.FuncRef1(module_name, func_name, line) ->
      erl_module_qualifier(erl_atom(module_name), erl_atom(func_name))
      |> erl_set_pos(line)

    ast.FuncRef0(name, line) -> erl_atom(name) |> erl_set_pos(line)

    ast.FuncRefStr(module_name, func_name, line) ->
      erl_module_qualifier(erl_atom(module_name), erl_atom(func_name))
      |> erl_set_pos(line)

    ast.FuncRefTuple(tuple_expr, func_name, line) ->
      erl_module_qualifier(
        expr_to_erl(tuple_expr, ctx, ExprMode),
        erl_atom(func_name),
      )
      |> erl_set_pos(line)

    ast.FuncRefExpr(inner) -> expr_to_erl(inner, ctx, ExprMode)

    // Get function: &func/arity
    ast.GetFunc1(func_name, arity_expr, line) ->
      erl_implicit_fun(
        erl_arity_qualifier(
          erl_atom(func_name) |> erl_set_pos(line),
          expr_to_erl(arity_expr, ctx, ExprMode) |> erl_set_pos(line),
        ),
      )
      |> erl_set_pos(line)

    ast.GetFunc2(module_name, func_name, arity_expr, line) ->
      erl_implicit_fun(
        erl_module_qualifier(
          erl_atom(module_name) |> erl_set_pos(line),
          erl_arity_qualifier(
            erl_atom(func_name) |> erl_set_pos(line),
            expr_to_erl(arity_expr, ctx, ExprMode) |> erl_set_pos(line),
          ),
        )
          |> erl_set_pos(line),
      )
      |> erl_set_pos(line)

    // If expression -> case expression
    ast.IfExpr(condition, then_body, [], line) ->
      erl_case_expr(expr_to_erl(condition, ctx, ExprMode), [
        erl_clause([erl_atom("false")], [], [erl_nil()]),
        erl_clause([erl_atom("nil")], [], [erl_nil()]),
        erl_clause(
          [erl_variable("_")],
          [],
          list.map(then_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
      ])
      |> erl_set_pos(line)

    ast.IfExpr(condition, then_body, else_body, line) ->
      erl_case_expr(expr_to_erl(condition, ctx, ExprMode), [
        erl_clause(
          [erl_atom("false")],
          [],
          list.map(else_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
        erl_clause(
          [erl_atom("nil")],
          [],
          list.map(else_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
        erl_clause(
          [erl_variable("_")],
          [],
          list.map(then_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
      ])
      |> erl_set_pos(line)

    ast.ElsifExpr(condition, then_body, [], line) ->
      erl_case_expr(expr_to_erl(condition, ctx, ExprMode), [
        erl_clause([erl_atom("false")], [], [erl_nil()]),
        erl_clause([erl_atom("nil")], [], [erl_nil()]),
        erl_clause(
          [erl_variable("_")],
          [],
          list.map(then_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
      ])
      |> erl_set_pos(line)

    ast.ElsifExpr(condition, then_body, else_body, line) ->
      erl_case_expr(expr_to_erl(condition, ctx, ExprMode), [
        erl_clause(
          [erl_atom("false")],
          [],
          list.map(else_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
        erl_clause(
          [erl_atom("nil")],
          [],
          list.map(else_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
        erl_clause(
          [erl_variable("_")],
          [],
          list.map(then_body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
        ),
      ])
      |> erl_set_pos(line)

    // Match expression -> case expression
    ast.MatchExpr(value, clauses, line) ->
      erl_case_expr(
        expr_to_erl(value, ctx, ExprMode),
        list.map(clauses, fn(c) { expr_to_erl(c, ctx, ExprMode) }),
      )
      |> erl_set_pos(line)

    // Case clause
    ast.CaseClause(patterns, guards, body) -> {
      let guard_ctx =
        Context(..ctx, context_stack: [ast.GuardContext, ..ctx.context_stack])
      make_clause(
        list.map(patterns, fn(p) { expr_to_erl(p, ctx, PatternMode) }),
        list.map(guards, fn(g) { expr_to_erl(g, guard_ctx, ExprMode) }),
        list.map(body, fn(b) { expr_to_erl(b, ctx, ExprMode) }),
      )
    }

    // Receive
    ast.ReceiveExpr(clauses, line) ->
      erl_receive_expr(
        list.map(clauses, fn(c) { expr_to_erl(c, ctx, ExprMode) }),
      )
      |> erl_set_pos(line)

    ast.ReceiveAfterExpr(clauses, timeout, actions, line) ->
      erl_receive_expr_timeout(
        list.map(clauses, fn(c) { expr_to_erl(c, ctx, ExprMode) }),
        expr_to_erl(timeout, ctx, ExprMode),
        list.map(actions, fn(a) { expr_to_erl(a, ctx, ExprMode) }),
      )
      |> erl_set_pos(line)

    // Lambda
    ast.Lambda(args, guards, body, _line) -> {
      let lambda_ctx =
        Context(
          ..ctx,
          context_stack: [ast.BlockLambda, ..ctx.context_stack],
        )
      let guard_ctx =
        Context(
          ..lambda_ctx,
          context_stack: [ast.GuardContext, ..lambda_ctx.context_stack],
        )
      let clause =
        make_clause(
          list.map(args, fn(a) { expr_to_erl(a, lambda_ctx, PatternMode) }),
          list.map(guards, fn(g) { expr_to_erl(g, guard_ctx, ExprMode) }),
          list.map(body, fn(b) { expr_to_erl(b, lambda_ctx, ExprMode) }),
        )
      erl_fun_expr([clause])
    }

    // Lists
    ast.ListLit(elems, _line) ->
      erl_list(list.map(elems, fn(e) { expr_to_erl(e, ctx, mode) }))

    ast.Cons(head, tail, _line) ->
      erl_cons(
        expr_to_erl(head, ctx, mode),
        expr_to_erl(tail, ctx, mode),
      )

    // Tuples
    ast.TupleLit(elems, _line) ->
      erl_tuple(list.map(elems, fn(e) { expr_to_erl(e, ctx, mode) }))

    // Maps
    ast.MapExpr(fields, _line) ->
      erl_map_expr(list.map(fields, fn(f) { expr_to_erl(f, ctx, mode) }))

    ast.MapField(key, value, _line) ->
      case mode {
        ExprMode ->
          erl_map_field_assoc(
            expr_to_erl(key, ctx, ExprMode),
            expr_to_erl(value, ctx, ExprMode),
          )
        PatternMode ->
          erl_map_field_exact(
            expr_to_erl(key, ctx, PatternMode),
            expr_to_erl(value, ctx, PatternMode),
          )
      }

    ast.MapFieldAtom(key, value, line) ->
      case mode {
        ExprMode ->
          erl_map_field_assoc(
            erl_atom(key) |> erl_set_pos(line),
            expr_to_erl(value, ctx, ExprMode),
          )
          |> erl_set_pos(line)
        PatternMode ->
          erl_map_field_exact(
            erl_atom(key) |> erl_set_pos(line),
            expr_to_erl(value, ctx, PatternMode),
          )
          |> erl_set_pos(line)
      }

    // Binaries
    ast.BinaryLit(fields, line) ->
      erl_binary(list.map(fields, fn(f) { expr_to_erl(f, ctx, mode) }))
      |> erl_set_pos(line)

    ast.BinaryField1(value) ->
      erl_binary_field1(expr_to_erl(value, ctx, mode))

    ast.BinaryField2(value, types) ->
      erl_binary_field2(
        expr_to_erl(value, ctx, mode),
        list.map(types, fn(t) { expr_to_erl(t, ctx, ExprMode) }),
      )

    ast.BinaryFieldSize(value, size, ast.DefaultTypes) ->
      erl_binary_field3(
        expr_to_erl(value, ctx, mode),
        expr_to_erl(size, ctx, mode),
        [erl_atom("integer")],
      )

    ast.BinaryFieldSizeTypes(value, size, types) ->
      erl_binary_field3(
        expr_to_erl(value, ctx, mode),
        expr_to_erl(size, ctx, mode),
        list.map(types, fn(t) { expr_to_erl(t, ctx, ExprMode) }),
      )

    // Range: a..b -> lists:seq(a, b)
    ast.Range(from, to, line) -> {
      let seq_fn = erl_module_qualifier(erl_atom("lists"), erl_atom("seq"))
      erl_application(seq_fn, [
        expr_to_erl(from, ctx, ExprMode),
        expr_to_erl(to, ctx, ExprMode),
      ])
      |> erl_set_pos(line)
    }

    // ColonColon access: map::key -> maps:get(key, map)
    ast.ColonColonAccess(map_expr, key, line) -> {
      let maps_get = erl_module_qualifier(erl_atom("maps"), erl_atom("get"))
      erl_application(maps_get, [
        erl_atom(key),
        expr_to_erl(map_expr, ctx, ExprMode),
      ])
      |> erl_set_pos(line)
    }

    // Pipe: a | b -> a.pipe_to(b.to_task())
    ast.PipeOp(left, right, line) -> {
      let call_method =
        erl_module_qualifier(
          erl_atom("jet_runtime"),
          erl_atom("call_method"),
        )
      let to_task =
        erl_application(call_method, [
          expr_to_erl(right, ctx, ExprMode),
          erl_atom("to_task"),
          erl_list([]),
        ])
      erl_application(call_method, [
        expr_to_erl(left, ctx, ExprMode),
        erl_atom("pipe_to"),
        erl_list([to_task]),
      ])
      |> erl_set_pos(line)
    }

    // Send: receiver ! message
    ast.Send(receiver, message, line) ->
      erl_infix_expr(
        expr_to_erl(receiver, ctx, ExprMode),
        erl_operator("!"),
        expr_to_erl(message, ctx, ExprMode),
      )
      |> erl_set_pos(line)

    // Catch
    ast.CatchExpr(inner, line) ->
      erl_catch_expr(expr_to_erl(inner, ctx, ExprMode))
      |> erl_set_pos(line)

    // Comprehensions
    ast.ListComp(template, generators, guard, line) -> {
      let qualifiers =
        list.map(generators, fn(g) { expr_to_erl(g, ctx, ExprMode) })
      let all_qualifiers = case guard {
        [] -> qualifiers
        [g, ..] ->
          list.append(qualifiers, [expr_to_erl(g, ctx, ExprMode)])
      }
      erl_list_comp(expr_to_erl(template, ctx, ExprMode), all_qualifiers)
      |> erl_set_pos(line)
    }

    ast.BinaryComp(template, generators, guard, line) -> {
      let qualifiers =
        list.map(generators, fn(g) { expr_to_erl(g, ctx, ExprMode) })
      let all_qualifiers = case guard {
        [] -> qualifiers
        [g, ..] ->
          list.append(qualifiers, [expr_to_erl(g, ctx, ExprMode)])
      }
      erl_binary_comp(expr_to_erl(template, ctx, ExprMode), all_qualifiers)
      |> erl_set_pos(line)
    }

    ast.ListGenerator(pattern, body, line) ->
      erl_generator(
        expr_to_erl(pattern, ctx, PatternMode),
        expr_to_erl(body, ctx, ExprMode),
      )
      |> erl_set_pos(line)

    ast.BinaryGenerator(pattern, body, line) ->
      erl_binary_generator(
        expr_to_erl(pattern, ctx, PatternMode),
        expr_to_erl(body, ctx, ExprMode),
      )
      |> erl_set_pos(line)

    // Records
    ast.RecordExpr(name, fields, line) ->
      erl_record_expr(
        erl_atom(name) |> erl_set_pos(line),
        list.map(fields, fn(f) { expr_to_erl(f, ctx, mode) }),
      )
      |> erl_set_pos(line)

    ast.RecordField1(name, line) ->
      erl_record_field(erl_atom(name) |> erl_set_pos(line))
      |> erl_set_pos(line)

    ast.RecordField2(name, value, line) ->
      erl_record_field2(
        erl_atom(name) |> erl_set_pos(line),
        expr_to_erl(value, ctx, mode),
      )
      |> erl_set_pos(line)

    ast.RecordFieldIndex(record, field, line) ->
      erl_record_index_expr(
        erl_atom(record) |> erl_set_pos(line),
        erl_atom(field) |> erl_set_pos(line),
      )
      |> erl_set_pos(line)

    // Fun name/arity (for exports)
    ast.FunName(name, arity, line) ->
      erl_arity_qualifier(
        erl_atom(name) |> erl_set_pos(line),
        erl_integer(arity) |> erl_set_pos(line),
      )
      |> erl_set_pos(line)

    // Fallback
    _ -> erl_atom("undefined")
  }
}

// --- Binary operator compilation ---

fn compile_binop(
  op: ast.BinOperator,
  left: ast.Expr,
  right: ast.Expr,
  line: Int,
  ctx: Context,
  mode: Mode,
) -> ErlSyntax {
  let l = expr_to_erl(left, ctx, mode)
  let r = expr_to_erl(right, ctx, mode)
  let result = case op {
    ast.OpPlus -> erl_infix_expr(l, erl_operator("+"), r)
    ast.OpMinus -> erl_infix_expr(l, erl_operator("-"), r)
    ast.OpTimes -> erl_infix_expr(l, erl_operator("*"), r)
    ast.OpDiv -> erl_infix_expr(l, erl_operator("/"), r)
    ast.OpFloorDiv -> erl_infix_expr(l, erl_operator("div"), r)
    ast.OpPow -> {
      // Fix: use math:pow/2 instead of *
      let pow_fn = erl_module_qualifier(erl_atom("math"), erl_atom("pow"))
      erl_application(pow_fn, [l, r])
    }
    ast.OpPercent -> erl_infix_expr(l, erl_operator("rem"), r)
    ast.OpAppend -> erl_infix_expr(l, erl_operator("++"), r)
    ast.OpEqEq -> erl_infix_expr(l, erl_operator("=="), r)
    ast.OpBangEq -> erl_infix_expr(l, erl_operator("/="), r)
    ast.OpLt -> erl_infix_expr(l, erl_operator("<"), r)
    ast.OpGt -> erl_infix_expr(l, erl_operator(">"), r)
    ast.OpLtEq -> erl_infix_expr(l, erl_operator("=<"), r)
    ast.OpGtEq -> erl_infix_expr(l, erl_operator(">="), r)
    ast.OpAnd -> erl_infix_expr(l, erl_operator("andalso"), r)
    ast.OpOr -> erl_infix_expr(l, erl_operator("orelse"), r)
    ast.OpXor -> erl_infix_expr(l, erl_operator("xor"), r)
    ast.OpBand -> erl_infix_expr(l, erl_operator("band"), r)
    ast.OpBor -> erl_infix_expr(l, erl_operator("bor"), r)
    ast.OpBxor -> erl_infix_expr(l, erl_operator("bxor"), r)
    ast.OpBsl -> erl_infix_expr(l, erl_operator("bsl"), r)
    ast.OpBsr -> erl_infix_expr(l, erl_operator("bsr"), r)
  }
  result |> erl_set_pos(line)
}

// --- FFI declarations ---

@external(erlang, "jet_ffi", "erl_atom")
fn erl_atom(value: String) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_variable")
fn erl_variable(name: String) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_integer")
fn erl_integer(value: Int) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_float")
fn erl_float(value: Float) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_string")
fn erl_string(value: String) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_nil")
fn erl_nil() -> ErlSyntax

@external(erlang, "jet_ffi", "erl_cons")
fn erl_cons(head: ErlSyntax, tail: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_list")
fn erl_list(elements: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_tuple")
fn erl_tuple(elements: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_application")
fn erl_application(op: ErlSyntax, args: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_module_qualifier")
fn erl_module_qualifier(module: ErlSyntax, func: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_function")
fn erl_function(name: ErlSyntax, clauses: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_clause")
fn erl_clause(
  patterns: List(ErlSyntax),
  guards: List(ErlSyntax),
  body: List(ErlSyntax),
) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "make_clause")
fn make_clause(
  patterns: List(ErlSyntax),
  guards: List(ErlSyntax),
  body: List(ErlSyntax),
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_fun_expr")
fn erl_fun_expr(clauses: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_match_expr")
fn erl_match_expr(pattern: ErlSyntax, body: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_case_expr")
fn erl_case_expr(argument: ErlSyntax, clauses: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_receive_expr")
fn erl_receive_expr(clauses: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "erl_receive_expr_timeout")
fn erl_receive_expr_timeout(
  clauses: List(ErlSyntax),
  timeout: ErlSyntax,
  actions: List(ErlSyntax),
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_infix_expr")
fn erl_infix_expr(
  left: ErlSyntax,
  op: ErlSyntax,
  right: ErlSyntax,
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_prefix_expr")
fn erl_prefix_expr(op: ErlSyntax, arg: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_attribute")
fn erl_attribute(name: ErlSyntax, args: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_arity_qualifier")
fn erl_arity_qualifier(name: ErlSyntax, arity: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_map_expr")
fn erl_map_expr(fields: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_map_field_assoc")
fn erl_map_field_assoc(key: ErlSyntax, value: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_map_field_exact")
fn erl_map_field_exact(key: ErlSyntax, value: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_binary")
fn erl_binary(fields: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_binary_field")
fn erl_binary_field1(value: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "erl_binary_field2")
fn erl_binary_field2(value: ErlSyntax, types: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "erl_binary_field3")
fn erl_binary_field3(
  value: ErlSyntax,
  size: ErlSyntax,
  types: List(ErlSyntax),
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_record_expr")
fn erl_record_expr(name: ErlSyntax, fields: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_record_field")
fn erl_record_field(name: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "erl_record_field2")
fn erl_record_field2(name: ErlSyntax, value: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_record_index_expr")
fn erl_record_index_expr(
  record: ErlSyntax,
  field: ErlSyntax,
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_list_comp")
fn erl_list_comp(template: ErlSyntax, qualifiers: List(ErlSyntax)) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_binary_comp")
fn erl_binary_comp(
  template: ErlSyntax,
  qualifiers: List(ErlSyntax),
) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_generator")
fn erl_generator(pattern: ErlSyntax, body: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_binary_generator")
fn erl_binary_generator(pattern: ErlSyntax, body: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_catch_expr")
fn erl_catch_expr(expr: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_implicit_fun")
fn erl_implicit_fun(aq: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_operator")
fn erl_operator(op: String) -> ErlSyntax

@external(erlang, "jet_ffi", "erl_set_pos")
fn erl_set_pos(tree: ErlSyntax, line: Int) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "erl_function_name_str")
fn erl_function_name_str(func: ErlSyntax) -> String

@external(erlang, "jet_codegen_ffi", "erl_function_arity_int")
fn erl_function_arity_int(func: ErlSyntax) -> Int

@external(erlang, "jet_ffi", "erl_function_clauses")
fn erl_function_clauses(func: ErlSyntax) -> List(ErlSyntax)

@external(erlang, "jet_codegen_ffi", "erl_function_name_node")
fn erl_function_name_node(func: ErlSyntax) -> ErlSyntax

@external(erlang, "jet_codegen_ffi", "do_compile_forms")
fn do_compile_forms(
  forms: List(ErlSyntax),
) -> Result(#(ErlDynamic, BitArray), String)
