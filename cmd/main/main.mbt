extern "c" fn native_exit(code : Int) = "exit"

///|
async fn main {
  let argv = @env.args()
  let args = if argv.length() > 1 { argv[1:].to_array() } else { [] }
  let exit_code = @lib.run_cli(args, @stdio.stdin, @stdio.stdout)
  if exit_code != 0 {
    native_exit(exit_code)
  }
}
