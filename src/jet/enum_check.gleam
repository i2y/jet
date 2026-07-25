//// Exhaustiveness warnings for `match` over an `enum(...)` schema.
////
//// Jet is dynamically typed on purpose -- the LLM boundary can only be checked
//// at runtime, and `Architect`/`Flow` generate their topology at runtime, which
//// no static type could express. But an `enum(:a, :b, :c)` is a CLOSED SET that
//// is written down in the source, and the arms of a `match` are written down in
//// the source too. The compiler already knows both; they were simply never
//// connected. This connects them.
////
//// It is not a type system: it is a targeted analysis over a small, declared,
//// closed domain.
////
//// Scope, stated honestly: the analysis is INTRA-FUNCTION. It tracks
//// `x = Agent.spawn(...)` within one function body and checks `match x.m(...)`
//// there. An agent spawned in one function and matched in another is out of
//// reach -- a dynamic language gives no way to know what a parameter holds.
//// Missing a case is a warning, never an error.

import gleam/dict.{type Dict}
import gleam/io
import gleam/list
import gleam/set
import gleam/string
import jet/ast.{type Expr, type TopLevel}

/// Enum-valued methods, keyed by "Agent.method".
pub type Enums =
  Dict(String, List(String))

/// One module in isolation -- what a single-file `jet Foo.jet` can see.
pub fn check(module: ast.Module) -> Nil {
  check_with(module, collect(module.body, dict.new()))
}

/// Every enum-valued method across a whole project. `jet build src/` parses all
/// files before compiling any, so a `match` in one module can be checked against
/// an `expose … -> enum(...)` declared in another -- the case a per-module macro
/// cannot reach, because it only ever sees its own expansion.
///
/// An agent name defined twice with DIFFERENT values is dropped rather than
/// guessed at: a wrong warning is worse than a missing one.
pub fn collect_project(modules: List(ast.Module)) -> Enums {
  let #(table, ambiguous) =
    list.fold(modules, #(dict.new(), set.new()), fn(acc, m) {
      let #(table, bad) = acc
      dict.fold(collect(m.body, dict.new()), #(table, bad), fn(acc2, k, v) {
        let #(t, b) = acc2
        case dict.get(t, k) {
          Ok(existing) if existing != v -> #(t, set.insert(b, k))
          _ -> #(dict.insert(t, k, v), b)
        }
      })
    })
  dict.filter(table, fn(k, _) { !set.contains(ambiguous, k) })
}

pub fn check_with(module: ast.Module, enums: Enums) -> Nil {
  case dict.is_empty(enums) {
    True -> Nil
    False -> list.each(module.body, fn(t) { check_toplevel(t, enums) })
  }
}

// ---------------------------------------------------------------- collect ---
// An `expose m(args) -> enum(...)` was desugared by the parser into a method
// whose whole body is {:jet_agent_async, config, :m, [args], schema, kind}, so
// the declared schema is still recoverable from the AST.

fn collect(body: List(TopLevel), acc: Enums) -> Enums {
  case body {
    [] -> acc
    [ast.ClassDef(name, _, methods, _), ..rest] ->
      collect(rest, collect_methods(name, methods, acc))
    [_, ..rest] -> collect(rest, acc)
  }
}

fn collect_methods(agent: String, methods: List(TopLevel), acc: Enums) -> Enums {
  list.fold(methods, acc, fn(acc, m) {
    case m {
      ast.FuncDef(_, _, _, _, [body], _) ->
        case async_marker(body) {
          Ok(#(mname, values)) ->
            dict.insert(acc, agent <> "." <> mname, values)
          Error(_) -> acc
        }
      _ -> acc
    }
  })
}

fn async_marker(body: Expr) -> Result(#(String, List(String)), Nil) {
  case body {
    ast.TupleLit(
      [
        ast.AtomLit("jet_agent_async", _),
        _config,
        ast.AtomLit(mname, _),
        _args,
        schema,
        _kind,
      ],
      _,
    ) ->
      case enum_values(schema) {
        Ok(values) -> Ok(#(mname, values))
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn enum_values(schema: Expr) -> Result(List(String), Nil) {
  case schema {
    // a description wraps the type; an OPTIONAL enum is skipped, since absence
    // is then legitimate and "you forgot a value" would be the wrong advice
    ast.TupleLit([ast.AtomLit("desc", _), inner, _], _) -> enum_values(inner)
    ast.TupleLit([ast.AtomLit("optional", _), _], _) -> Error(Nil)
    ast.TupleLit([ast.AtomLit("enum", _), ast.ListLit(vs, _)], _) ->
      Ok(
        list.filter_map(vs, fn(v) {
          case v {
            ast.AtomLit(a, _) -> Ok(a)
            _ -> Error(Nil)
          }
        }),
      )
    _ -> Error(Nil)
  }
}

// ------------------------------------------------------------------ check ---

fn check_toplevel(t: TopLevel, enums: Enums) -> Nil {
  case t {
    ast.FuncDef(_, _, _, _, body, _) -> {
      scan(body, dict.new(), enums)
      Nil
    }
    ast.ClassDef(_, _, methods, _) ->
      list.each(methods, fn(m) { check_toplevel(m, enums) })
    _ -> Nil
  }
}

/// Walk a function body in order, remembering `x = Agent.spawn(...)`, and check
/// every `match` whose subject resolves to an enum-valued agent method.
fn scan(body: List(Expr), vars: Dict(String, String), enums: Enums) -> Nil {
  case body {
    [] -> Nil
    [e, ..rest] -> {
      let vars = case e {
        ast.Assign(ast.Var(v, _), value, _) ->
          case spawned_agent(value) {
            Ok(agent) -> dict.insert(vars, v, agent)
            Error(_) -> dict.delete(vars, v)
          }
        _ -> vars
      }
      check_expr(e, vars, enums)
      scan(rest, vars, enums)
    }
  }
}

fn check_expr(e: Expr, vars: Dict(String, String), enums: Enums) -> Nil {
  case e {
    ast.MatchExpr(subject, clauses, line) -> {
      case enum_of_subject(subject, vars, enums) {
        Ok(#(label, values)) -> report(label, values, clauses, line)
        Error(_) -> Nil
      }
      list.each(clauses, fn(c) {
        case c {
          ast.CaseClause(_, _, cbody) -> scan(cbody, vars, enums)
          _ -> Nil
        }
      })
    }
    // The nesting a match realistically sits inside. Not a complete traversal
    // of every Expr variant -- a missed nesting only means a check we did not
    // run, never a wrong warning.
    ast.Assign(_, value, _) -> check_expr(value, vars, enums)
    ast.IfExpr(cond, then_body, else_body, _) -> {
      let _ = check_expr(cond, vars, enums)
      let _ = scan(then_body, vars, enums)
      scan(else_body, vars, enums)
    }
    ast.ElsifExpr(cond, then_body, else_body, _) -> {
      let _ = check_expr(cond, vars, enums)
      let _ = scan(then_body, vars, enums)
      scan(else_body, vars, enums)
    }
    ast.Lambda(_, _, lbody, _) -> scan(lbody, vars, enums)
    ast.ReceiveExpr(clauses, _) -> each_clause(clauses, vars, enums)
    ast.Apply(f, args, _) -> each_expr([f, ..args], vars, enums)
    ast.ApplyName(f, args, _) -> each_expr([f, ..args], vars, enums)
    ast.MethodCall(obj, _, args, _) -> each_expr([obj, ..args], vars, enums)
    ast.BinOp(_, l, r, _) -> each_expr([l, r], vars, enums)
    ast.UnaryOp(_, o, _) -> check_expr(o, vars, enums)
    ast.ListLit(elems, _) -> each_expr(elems, vars, enums)
    ast.TupleLit(elems, _) -> each_expr(elems, vars, enums)
    ast.MapExpr(fields, _) -> each_expr(fields, vars, enums)
    ast.MapField(_, v, _) -> check_expr(v, vars, enums)
    ast.MapFieldAtom(_, v, _) -> check_expr(v, vars, enums)
    _ -> Nil
  }
}

fn each_expr(es: List(Expr), vars: Dict(String, String), enums: Enums) -> Nil {
  list.each(es, fn(e) { check_expr(e, vars, enums) })
}

fn each_clause(cs: List(Expr), vars: Dict(String, String), enums: Enums) -> Nil {
  list.each(cs, fn(c) {
    case c {
      ast.CaseClause(_, _, cbody) -> scan(cbody, vars, enums)
      _ -> Nil
    }
  })
}

/// `x.assess(d)`, `x.assess(d).await()`, `x.assess(d).stream(...)` -> the enum
/// declared for that agent method.
fn enum_of_subject(
  subject: Expr,
  vars: Dict(String, String),
  enums: Enums,
) -> Result(#(String, List(String)), Nil) {
  case strip_future(subject) {
    ast.MethodCall(ast.Var(v, _), method, _, _) ->
      case dict.get(vars, v) {
        Ok(agent) -> {
          let key = agent <> "." <> method
          case dict.get(enums, key) {
            Ok(values) -> Ok(#(key, values))
            Error(_) -> Error(Nil)
          }
        }
        Error(_) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn strip_future(e: Expr) -> Expr {
  case e {
    ast.MethodCall(inner, "await", [], _) -> strip_future(inner)
    ast.MethodCall(inner, "stream", _, _) -> strip_future(inner)
    _ -> e
  }
}

// ----------------------------------------------------------------- report ---

fn report(
  label: String,
  values: List(String),
  clauses: List(Expr),
  line: Int,
) -> Nil {
  let covered = list.fold(clauses, set.new(), fn(acc, c) { arm_atoms(c, acc) })
  let missing = list.filter(values, fn(v) { !set.contains(covered, v) })
  let unknown =
    set.to_list(covered)
    |> list.filter(fn(a) { !list.contains(values, a) })
    |> list.sort(string.compare)

  // an arm that matches anything already covers the rest
  case has_wildcard(clauses) || missing == [] {
    True -> Nil
    False ->
      io.println(
        "Warning: line "
        <> int_to_string(line)
        <> ": match on "
        <> label
        <> " does not cover "
        <> string.join(list.map(missing, fn(v) { ":" <> v }), ", ")
        <> " (declared enum: "
        <> string.join(values, " | ")
        <> ")",
      )
  }

  case unknown {
    [] -> Nil
    _ ->
      io.println(
        "Warning: line "
        <> int_to_string(line)
        <> ": match on "
        <> label
        <> " has a case for "
        <> string.join(list.map(unknown, fn(v) { ":" <> v }), ", ")
        <> ", which the declared enum does not contain ("
        <> string.join(values, " | ")
        <> ")",
      )
  }
}

/// Atoms an arm matches on: `case :stale` and `case {:ok, :stale}` both count.
/// The `:ok` / `:error` tags of the turn's own result wrapper are not values.
fn arm_atoms(clause: Expr, acc: set.Set(String)) -> set.Set(String) {
  case clause {
    ast.CaseClause(patterns, _, _) ->
      list.fold(patterns, acc, fn(acc, p) {
        case p {
          ast.AtomLit(a, _) -> add_value(acc, a)
          ast.TupleLit(elems, _) ->
            list.fold(elems, acc, fn(acc, el) {
              case el {
                ast.AtomLit(a, _) -> add_value(acc, a)
                _ -> acc
              }
            })
          _ -> acc
        }
      })
    _ -> acc
  }
}

fn add_value(acc: set.Set(String), a: String) -> set.Set(String) {
  case a {
    "ok" | "error" -> acc
    _ -> set.insert(acc, a)
  }
}

/// Does some arm already cover every remaining value? Only `case _` and
/// `case {:ok, v}` do. `case {:error, _}` looks like a wildcard but matches a
/// DIFFERENT tag -- treating it as one silently disabled the whole check.
/// A guarded arm covers nothing, since the guard may fail.
fn has_wildcard(clauses: List(Expr)) -> Bool {
  list.any(clauses, fn(c) {
    case c {
      ast.CaseClause([ast.Var(_, _)], [], _) -> True
      ast.CaseClause(
        [ast.TupleLit([ast.AtomLit("ok", _), ast.Var(_, _)], _)],
        [],
        _,
      ) -> True
      _ -> False
    }
  })
}

fn int_to_string(i: Int) -> String {
  string.inspect(i)
}

// ------------------------------------------------------------------ spawn ---

/// `Agent.spawn(...)` / `module::Agent.spawn(...)` -> the agent's name.
fn spawned_agent(value: Expr) -> Result(String, Nil) {
  case value {
    ast.MethodCall(receiver, "spawn", _, _) -> receiver_name(receiver)
    _ -> Error(Nil)
  }
}

fn receiver_name(e: Expr) -> Result(String, Nil) {
  case e {
    ast.Var(name, _) -> Ok(name)
    ast.FuncRef1(_, name, _) -> Ok(name)
    ast.Apply(inner, [], _) -> receiver_name(inner)
    _ -> Error(Nil)
  }
}
