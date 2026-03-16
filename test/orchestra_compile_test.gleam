import gleeunit
import jet/codegen/beam
import jet/error
import jet/lexer
import jet/parser
import jet/rebind
import jet/token_filter
import simplifile

pub fn main() {
  gleeunit.main()
}

/// Full pipeline: lex → parse → codegen → compile:forms
/// Works for module-only files (no class/actor @attr)
fn compile_jet_file(
  path: String,
  module_name: String,
) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(source) -> {
      case lexer.lex(source) {
        Ok(tokens) -> {
          let filtered = token_filter.filter(tokens, module_name)
          case parser.parse(filtered, module_name) {
            Ok(module) -> {
              let module = rebind.rename_module(module)
              case beam.compile(module) {
                Ok(_) -> Ok(Nil)
                Error(e) -> Error("codegen: " <> error.format(e))
              }
            }
            Error(e) -> Error("parse: " <> error.format(e))
          }
        }
        Error(e) -> Error("lex: " <> error.format(e))
      }
    }
    Error(_) -> Error("file not found: " <> path)
  }
}

// --- Core modules ---

pub fn compile_log_test() {
  let assert Ok(_) = compile_jet_file("src/jet_orchestra/Log.jet", "Log")
}

pub fn compile_backoff_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/Backoff.jet",
    "Backoff",
  )
}

pub fn compile_hooks_test() {
  let assert Ok(_) = compile_jet_file("src/jet_orchestra/Hooks.jet", "Hooks")
}

pub fn compile_runner_test() {
  let assert Ok(_) = compile_jet_file("src/jet_orchestra/Runner.jet", "Runner")
}

pub fn compile_task_source_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/TaskSource.jet",
    "TaskSource",
  )
}

pub fn compile_workspace_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/Workspace.jet",
    "Workspace",
  )
}

pub fn compile_python_bridge_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/PythonBridge.jet",
    "PythonBridge",
  )
}

pub fn compile_config_test() {
  let assert Ok(_) = compile_jet_file("src/jet_orchestra/Config.jet", "Config")
}

pub fn compile_worker_test() {
  let assert Ok(_) = compile_jet_file("src/jet_orchestra/Worker.jet", "Worker")
}

pub fn compile_scheduler_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/Scheduler.jet",
    "Scheduler",
  )
}

pub fn compile_workflow_router_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/WorkflowRouter.jet",
    "WorkflowRouter",
  )
}

pub fn compile_dets_store_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra/DetsStore.jet",
    "DetsStore",
  )
}

// --- Runner implementations ---

pub fn compile_claude_code_runner_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra_runners/ClaudeCodeRunner.jet",
    "ClaudeCodeRunner",
  )
}

pub fn compile_claude_agent_runner_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra_runners/ClaudeAgentRunner.jet",
    "ClaudeAgentRunner",
  )
}

pub fn compile_codex_runner_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra_runners/CodexRunner.jet",
    "CodexRunner",
  )
}

// --- Source implementations (full compile) ---

pub fn compile_github_task_source_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra_sources/GitHubTaskSource.jet",
    "GitHubTaskSource",
  )
}

pub fn compile_linear_task_source_test() {
  let assert Ok(_) = compile_jet_file(
    "src/jet_orchestra_sources/LinearTaskSource.jet",
    "LinearTaskSource",
  )
}

// --- Examples ---

pub fn compile_mock_task_source_test() {
  let assert Ok(_) = compile_jet_file(
    "examples/orchestra/MockTaskSource.jet",
    "MockTaskSource",
  )
}

pub fn compile_simple_demo_test() {
  let assert Ok(_) = compile_jet_file(
    "examples/orchestra/SimpleDemo.jet",
    "SimpleDemo",
  )
}

pub fn compile_github_claude_demo_test() {
  let assert Ok(_) = compile_jet_file(
    "examples/orchestra/GitHubClaudeDemo.jet",
    "GitHubClaudeDemo",
  )
}

pub fn compile_test_workflow_router_test() {
  let assert Ok(_) = compile_jet_file(
    "examples/orchestra/TestWorkflowRouter.jet",
    "TestWorkflowRouter",
  )
}
