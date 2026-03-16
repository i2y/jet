import gleeunit/should
import jet/ast
import jet/rebind

pub fn simple_rebinding_test() {
  // x = 1; x = x + 1 → x = 1; x_v1 = x + 1
  let module =
    ast.Module(name: "test", line: 1, body: [
      ast.FuncDef(
        name: "foo",
        line: 1,
        args: [],
        guards: [],
        body: [
          ast.Assign(ast.Var("x", 1), ast.IntLit(1, 1), 1),
          ast.Assign(
            ast.Var("x", 2),
            ast.BinOp(ast.OpPlus, ast.Var("x", 2), ast.IntLit(1, 2), 2),
            2,
          ),
        ],
        context: ast.ModuleMethod,
      ),
    ])

  let result = rebind.rename_module(module)
  case result.body {
    [ast.FuncDef(_, _, _, _, body, _)] -> {
      // First assignment: x = 1 (first binding, keeps original name)
      case body {
        [ast.Assign(ast.Var(name1, _), _, _), ast.Assign(ast.Var(name2, _), ast.BinOp(_, ast.Var(ref_name, _), _, _), _)] -> {
          should.equal(name1, "x")
          should.equal(name2, "x_v1")
          should.equal(ref_name, "x")
        }
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

pub fn triple_rebinding_test() {
  // x = 1; x = 2; x = 3 → x = 1; x_v1 = 2; x_v2 = 3
  let module =
    ast.Module(name: "test", line: 1, body: [
      ast.FuncDef(
        name: "foo",
        line: 1,
        args: [],
        guards: [],
        body: [
          ast.Assign(ast.Var("x", 1), ast.IntLit(1, 1), 1),
          ast.Assign(ast.Var("x", 2), ast.IntLit(2, 2), 2),
          ast.Assign(ast.Var("x", 3), ast.IntLit(3, 3), 3),
        ],
        context: ast.ModuleMethod,
      ),
    ])

  let result = rebind.rename_module(module)
  case result.body {
    [ast.FuncDef(_, _, _, _, body, _)] ->
      case body {
        [ast.Assign(ast.Var(n1, _), _, _), ast.Assign(ast.Var(n2, _), _, _), ast.Assign(ast.Var(n3, _), _, _)] -> {
          should.equal(n1, "x")
          should.equal(n2, "x_v1")
          should.equal(n3, "x_v2")
        }
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn func_arg_rebinding_test() {
  // def foo(x); x = x + 1 → def foo(x); x_v1 = x + 1
  let module =
    ast.Module(name: "test", line: 1, body: [
      ast.FuncDef(
        name: "foo",
        line: 1,
        args: [ast.Var("x", 1)],
        guards: [],
        body: [
          ast.Assign(
            ast.Var("x", 2),
            ast.BinOp(ast.OpPlus, ast.Var("x", 2), ast.IntLit(1, 2), 2),
            2,
          ),
        ],
        context: ast.ModuleMethod,
      ),
    ])

  let result = rebind.rename_module(module)
  case result.body {
    [ast.FuncDef(_, _, _, _, body, _)] ->
      case body {
        [ast.Assign(ast.Var(lhs, _), ast.BinOp(_, ast.Var(rhs, _), _, _), _)] -> {
          should.equal(lhs, "x_v1")
          should.equal(rhs, "x")
        }
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn no_rebinding_unchanged_test() {
  // x = 1; y = 2 → unchanged
  let module =
    ast.Module(name: "test", line: 1, body: [
      ast.FuncDef(
        name: "foo",
        line: 1,
        args: [],
        guards: [],
        body: [
          ast.Assign(ast.Var("x", 1), ast.IntLit(1, 1), 1),
          ast.Assign(ast.Var("y", 2), ast.IntLit(2, 2), 2),
        ],
        context: ast.ModuleMethod,
      ),
    ])

  let result = rebind.rename_module(module)
  case result.body {
    [ast.FuncDef(_, _, _, _, body, _)] ->
      case body {
        [ast.Assign(ast.Var(n1, _), _, _), ast.Assign(ast.Var(n2, _), _, _)] -> {
          should.equal(n1, "x")
          should.equal(n2, "y")
        }
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}

pub fn rebinding_in_expression_reference_test() {
  // x = 1; x = 2; y = x → y uses x_v1
  let module =
    ast.Module(name: "test", line: 1, body: [
      ast.FuncDef(
        name: "foo",
        line: 1,
        args: [],
        guards: [],
        body: [
          ast.Assign(ast.Var("x", 1), ast.IntLit(1, 1), 1),
          ast.Assign(ast.Var("x", 2), ast.IntLit(2, 2), 2),
          ast.Assign(ast.Var("y", 3), ast.Var("x", 3), 3),
        ],
        context: ast.ModuleMethod,
      ),
    ])

  let result = rebind.rename_module(module)
  case result.body {
    [ast.FuncDef(_, _, _, _, body, _)] ->
      case body {
        [_, _, ast.Assign(ast.Var(lhs, _), ast.Var(rhs, _), _)] -> {
          should.equal(lhs, "y")
          should.equal(rhs, "x_v1")
        }
        _ -> should.fail()
      }
    _ -> should.fail()
  }
}
