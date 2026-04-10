///|
pub struct ParsedArgs {
  show_help : Bool
  profiles_path : String?
}

///|
priv enum ProviderKind {
  Codex
  Claude
} derive(Eq)

///|
priv struct Provider {
  kind : ProviderKind
  name : String
  base_url : String
  api_key : String
  claude_env : Map[String, String]
}

///|
priv struct DefaultPaths {
  home_dir : String
  config_path : String
  auth_path : String
  claude_settings_path : String
}

///|
priv struct ApplySummary {
  provider_label : String
  updated_files : Array[String]
}

///|
priv enum ProviderChoice {
  Select(String)
  Cancel
  Back
}

///|
priv enum ProviderKindChoice {
  SelectKind(ProviderKind)
  CancelKind
}

///|
pub(all) suberror CliError {
  CliError(String)
} derive(Eq, Show, ToJson)

///|
fn[T] cli_error(message : String) -> T raise CliError {
  raise CliError(message)
}

///|
fn help_text() -> String {
  (
    #|switch-codex updates Codex and Claude provider settings from a TOML file.
    #|
    #|Usage:
    #|  switch-codex [OPTIONS]
    #|
    #|Options:
    #|  --profiles <PATH>  Path to the source TOML file with [[codex]] / [[claude]].
    #|                     Defaults to ~/.moon-switch/providers.toml
    #|  -h, --help         Show this help text.
    #|
    #|Source format:
    #|  [[codex]]
    #|  name = "OpenAI"
    #|  base_url = "https://api.openai.com/v1"
    #|  api_key = "sk-..."
    #|
    #|  [[claude]]
    #|  name = "Claude Router"
    #|  base_url = "https://example.com"
    #|  api_key = "token"
    #|  ANTHROPIC_MODEL = "claude-sonnet-4-6"
    #|
    #|Target files:
    #|  - ~/.codex/config.toml
    #|  - ~/.codex/auth.json
    #|  - ~/.claude/settings.json
    #|
    #|Interactive selection:
    #|  - If both codex and claude exist, first choose the client
    #|  - Then choose one provider under that client
    #|  - Use ↑/↓ or j/k to move
    #|  - Type a number to jump
    #|  - Press Enter to confirm
    #|  - Press b to go back to client selection
    #|  - Type 0 to exit without changes
    #|
  )
}

///|
pub async fn run_cli(
  argv : Array[String],
  input : &@io.Reader,
  output : &@io.Writer,
) -> Int {
  let parsed = parse_args(argv) catch {
    CliError(message) => {
      output.write("error: \{message}\n\n\{help_text()}")
      return 2
    }
  }
  if parsed.show_help {
    output.write(help_text())
    return 0
  }

  let defaults = resolve_default_paths() catch {
    err => {
      output.write("error: \{err}\n")
      return 1
    }
  }
  
  let profiles_path = match parsed.profiles_path {
    Some(profile_arg) => expand_home(profile_arg, defaults.home_dir)
    None => ensure_default_config(defaults.home_dir, output) catch {
      err => {
        output.write("error: \{err}\n")
        return 1
      }
    }
  }
  
  let providers = load_providers(profiles_path) catch {
    err => {
      output.write("error: failed to load providers from \{profiles_path}: \{err}\n")
      return 1
    }
  }
  let selection = prompt_for_provider(providers, input, output) catch {
    err => {
      output.write("error: \{err}\n")
      return 1
    }
  }
  guard selection is Select(selected_name) else {
    output.write("Cancelled.\n")
    return 0
  }
  let provider = find_provider(providers, selected_name) catch {
    CliError(message) => {
      output.write("error: \{message}\n")
      return 1
    }
  }
  let summary = apply_provider(
    provider,
    defaults.config_path,
    defaults.auth_path,
    defaults.claude_settings_path,
  ) catch {
    err => {
      output.write("error: failed to apply provider \{selected_name}: \{err}\n")
      return 1
    }
  }
  output.write("Applied provider \{summary.provider_label}.\n")
  output.write("Updated files:\n")
  for file in summary.updated_files {
    output.write("  - \{file}\n")
  }
  0
}

///|
fn parse_args(args : Array[String]) -> ParsedArgs raise CliError {
  match args {
    [] => { show_help: false, profiles_path: None }
    ["-h"] | ["--help"] => { show_help: true, profiles_path: None }
    _ => {
      let mut profiles_path : String? = None
      loop args {
        [] => ()
        ["-h"] | ["--help"] => return { show_help: true, profiles_path: None }
        ["--profiles", .. tail] => {
          guard tail is [path, .. next] else {
            cli_error("expected a path after --profiles")
          }
          guard profiles_path is None else {
            cli_error("--profiles may only be provided once")
          }
          profiles_path = Some(path)
          continue next.to_array()
        }
        [arg, .. next] if arg.has_prefix("--profiles=") => {
          guard profiles_path is None else {
            cli_error("--profiles may only be provided once")
          }
          let path = arg["--profiles=".length():].to_string()
          guard !path.is_empty() else {
            cli_error("--profiles requires a non-empty path")
          }
          profiles_path = Some(path)
          continue next.to_array()
        }
        [arg, ..] if arg.has_prefix("-") => cli_error("unknown option `\{arg}`")
        [arg, ..] => cli_error("unexpected argument `\{arg}`")
      }
      { show_help: false, profiles_path }
    }
  }
}

///|
async fn is_windows() -> Bool raise {
  // Try running a Unix-only command; if it fails, likely on Windows
  let (code, _) = @process.collect_stdout("uname", ["-s"])
  code != 0
}

///|
fn expand_home(path : String, home_dir : String) -> String {
  if path == "~" {
    home_dir
  } else if path.has_prefix("~/") {
    home_dir + path[1:].to_string()
  } else {
    path
  }
}

///|
async fn resolve_default_paths() -> DefaultPaths raise {
  let home_dir = resolve_home_dir() catch {
    err => cli_error("failed to resolve the home directory: \{err}")
  }
  {
    home_dir,
    config_path: home_dir + "/.codex/config.toml",
    auth_path: home_dir + "/.codex/auth.json",
    claude_settings_path: home_dir + "/.claude/settings.json",
  }
}

///|
fn default_profiles_dir(home_dir : String) -> String {
  home_dir + "/.moon-switch"
}

///|
fn default_profiles_path(home_dir : String) -> String {
  default_profiles_dir(home_dir) + "/providers.toml"
}

///|
fn template_providers_content() -> String {
  (
    #|# Moon Switch Provider Configuration
    #|# Edit this file to add your provider settings
    #|
    #|[[codex]]
    #|name = "Example Provider"
    #|base_url = "https://api.example.com/v1"
    #|api_key = "sk-your-api-key-here"
    #|
    #|[[claude]]
    #|name = "Example Claude Provider"
    #|base_url = "https://api.example.com/anthropic"
    #|api_key = "sk-your-api-key-here"
    #|ANTHROPIC_MODEL = "claude-sonnet-4-20250514"
    #|
  )
}

///|
async fn ensure_default_config(home_dir : String, output : &@io.Writer) -> String raise {
  let config_dir = default_profiles_dir(home_dir)
  let config_file = default_profiles_path(home_dir)
  
  if @fs.exists(config_file) {
    return config_file
  }
  
  // Create directory if it doesn't exist
  if !@fs.exists(config_dir) {
    @fs.mkdir(config_dir, permission=0o755, recursive=true) catch {
      err => cli_error("failed to create config directory \{config_dir}: \{err}")
    }
    output.write("Created config directory: \{config_dir}\n")
  }
  
  // Create template config file
  @fs.write_file(config_file, template_providers_content(), create=0o644) catch {
    err => cli_error("failed to create template config file \{config_file}: \{err}")
  }
  output.write("Created template config file: \{config_file}\n")
  output.write("Please edit this file to add your provider settings, then run again.\n")
  cli_error("template config created, please edit and run again")
}

///|
async fn resolve_home_dir() -> String raise {
  // Try platform-specific environment variables
  let is_win = is_windows() catch { _ => false }
  
  if is_win {
    // On Windows, try USERPROFILE first, then HOME
    let (code, output) = @process.collect_stdout("powershell", [
      "-Command",
      "$env:USERPROFILE",
    ])
    if code == 0 {
      let profile = output.text().trim(char_set=" \t\r\n").to_string() catch { _ => "" }
      if !profile.is_empty() {
        return profile
      }
    }
    // Fallback: try HOME on Windows
    let (code, output) = @process.collect_stdout("powershell", [
      "-Command",
      "$env:HOME",
    ])
    if code == 0 {
      let home = output.text().trim(char_set=" \t\r\n").to_string() catch { _ => "" }
      if !home.is_empty() {
        return home
      }
    }
  } else {
    // On Unix, try HOME first
    let (code, output) = @process.collect_stdout("sh", [
      "-c",
      "printf %s \"$HOME\"",
    ])
    let home = output.text().trim(char_set=" \t\r\n").to_string() catch {
      err => cli_error("failed to read HOME from shell output: \{err}")
    }
    if code == 0 && !home.is_empty() {
      return home
    }
  }
  
  // Fallback: derive from current working directory
  guard @env.current_dir() is Some(cwd) else {
    cli_error("HOME is unavailable and the current directory is unknown")
  }
  home_from_cwd(cwd).unwrap_or_else(() =>
    cli_error("HOME is unavailable and current directory `\{cwd}` is not under a standard home path")
  )
}

///|
fn home_from_cwd(cwd : String) -> String? {
  // Unix paths: /home/user or /Users/user (macOS)
  if cwd.has_prefix("/home/") || cwd.has_prefix("/Users/") {
    let parts = cwd.split("/").map(StringView::to_string).to_array()
    if parts.length() >= 3 {
      return Some("/" + parts[1] + "/" + parts[2])
    }
  }
  // Windows paths: C:\Users\user or D:\Users\user
  // Note: We use '/' here which works on Windows too after normalization
  let normalized = cwd.replace(old="\\", new="/")
  if normalized.has_prefix("/home/") || normalized.has_prefix("/Users/") {
    let parts = normalized.split("/").map(StringView::to_string).to_array()
    if parts.length() >= 3 {
      return Some(parts[0] + "/" + parts[1] + "/" + parts[2])
    }
  }
  // Handle drive letters like C:/Users/
  if normalized.length() >= 3 && normalized[1] == ':' && normalized[2] == '/' {
    let rest = normalized[3:].to_string()
    let parts = rest.split("/").map(StringView::to_string).to_array()
    if parts.length() >= 2 && parts[0] == "Users" && parts.length() >= 3 {
      return Some(normalized[0:1].to_string() + ":/Users/" + parts[1])
    }
  }
  None
}

///|
fn provider_kind_label(kind : ProviderKind) -> String {
  match kind {
    Codex => "codex"
    Claude => "claude"
  }
}

///|
fn provider_label(provider : Provider) -> String {
  "\{provider.name} [\{provider_kind_label(provider.kind)}]"
}

///|
fn provider_kind_title(kind : ProviderKind) -> String {
  match kind {
    Codex => "Codex"
    Claude => "Claude"
  }
}

///|
fn available_provider_kinds(providers : Array[Provider]) -> Array[ProviderKind] {
  let kinds : Array[ProviderKind] = []
  let mut has_codex = false
  let mut has_claude = false
  for provider in providers {
    match provider.kind {
      Codex if !has_codex => {
        has_codex = true
        kinds.push(Codex)
      }
      Claude if !has_claude => {
        has_claude = true
        kinds.push(Claude)
      }
      _ => ()
    }
  }
  kinds
}

///|
fn filter_providers_by_kind(
  providers : Array[Provider],
  kind : ProviderKind,
) -> Array[Provider] {
  providers.filter(provider => provider.kind == kind)
}

///|
fn parse_kind_selection(kinds : Array[ProviderKind], raw : String) -> ProviderKindChoice? {
  let labels = kinds.map(provider_kind_title)
  match parse_selection(labels, raw) {
    Some(Select(name)) => {
      for kind in kinds {
        if provider_kind_title(kind) == name {
          return Some(SelectKind(kind))
        }
      }
      None
    }
    Some(Cancel) => Some(CancelKind)
    Some(Back) => None
    None => None
  }
}

///|
fn parse_selection(names : Array[String], raw : String) -> ProviderChoice? {
  let choice = raw.trim(char_set=" \t\r\n").to_string()
  if choice.is_empty() {
    return None
  }
  let parsed_index = try? @string.parse_int(choice)
  match parsed_index {
    Ok(0) => return Some(Cancel)
    Ok(index) if index >= 1 && index <= names.length() =>
      return Some(Select(names[index - 1]))
    _ => ()
  }
  if names.contains(choice) {
    Some(Select(choice))
  } else if choice == "q" || choice == "quit" || choice == "exit" {
    Some(Cancel)
  } else {
    None
  }
}

///|
async fn prompt_for_provider(
  providers : Array[Provider],
  input : &@io.Reader,
  output : &@io.Writer,
) -> ProviderChoice raise {
  let kinds = available_provider_kinds(providers)
  if kinds.is_empty() {
    cli_error("the provider source does not define any selectable providers")
  }
  let can_go_back = kinds.length() > 1
  let mut selected_kind = if kinds.length() == 1 {
    kinds[0]
  } else {
    match prompt_for_provider_kind(kinds, input, output) {
      SelectKind(kind) => kind
      CancelKind => return Cancel
    }
  }
  while true {
    let filtered = filter_providers_by_kind(providers, selected_kind)
    if filtered.is_empty() {
      cli_error("the selected client does not define any selectable providers")
    }
    let result = match try_enable_raw_mode() {
      Some(snapshot) => {
        let selected = prompt_for_provider_with_cursor(
          filtered,
          input,
          output,
          can_go_back,
        ) catch {
          err => {
            ignore(try? restore_terminal(snapshot, output))
            raise err
          }
        }
        restore_terminal(snapshot, output)
        selected
      }
      None => prompt_for_provider_line_mode(filtered, input, output, can_go_back)
    }
    match result {
      Back => {
        match prompt_for_provider_kind(kinds, input, output) {
          SelectKind(kind) => selected_kind = kind
          CancelKind => return Cancel
        }
      }
      other => return other
    }
  } nobreak {
    cli_error("selection loop terminated unexpectedly")
  }
}

///|
async fn prompt_for_provider_kind(
  kinds : Array[ProviderKind],
  input : &@io.Reader,
  output : &@io.Writer,
) -> ProviderKindChoice raise {
  match try_enable_raw_mode() {
    Some(snapshot) => {
      let selected = prompt_for_provider_kind_with_cursor(
        kinds,
        input,
        output,
      ) catch {
        err => {
          ignore(try? restore_terminal(snapshot, output))
          raise err
        }
      }
      restore_terminal(snapshot, output)
      selected
    }
    None => prompt_for_provider_kind_line_mode(kinds, input, output)
  }
}

///|
async fn prompt_for_provider_kind_line_mode(
  kinds : Array[ProviderKind],
  input : &@io.Reader,
  output : &@io.Writer,
) -> ProviderKindChoice raise {
  if kinds.is_empty() {
    cli_error("the provider source does not define any selectable clients")
  }
  output.write("Available clients:\n")
  for i = 0; i < kinds.length(); i = i + 1 {
    output.write("  \{i + 1}. \{provider_kind_title(kinds[i])}\n")
  }
  output.write("  0. Exit without changes\n")
  while true {
    output.write("Select client [0-\{kinds.length()} or name]: ")
    guard input.read_until("\n") is Some(line) else {
      cli_error("selection input ended before a client was chosen")
    }
    match parse_kind_selection(kinds, line) {
      Some(choice) => return choice
      None => {
        output.write(
          "Invalid selection. Enter 0-\{kinds.length()}, an exact client name, or `q`: ",
        )
      }
    }
  } nobreak {
    cli_error("selection loop terminated unexpectedly")
  }
}

///|
async fn prompt_for_provider_kind_with_cursor(
  kinds : Array[ProviderKind],
  input : &@io.Reader,
  output : &@io.Writer,
) -> ProviderKindChoice raise {
  if kinds.is_empty() {
    cli_error("the provider source does not define any selectable clients")
  }
  output.write("\u001b[?25l")
  let total_choices = kinds.length() + 1
  let total_lines = kinds.length() + 4
  let mut selected = 0
  let mut digit_buffer = ""
  render_provider_kind_menu(kinds, selected, digit_buffer, output, false)
  while true {
    match read_menu_action(input) {
      MenuUp => {
        digit_buffer = ""
        selected = if selected == 0 { total_choices - 1 } else { selected - 1 }
        render_provider_kind_menu(kinds, selected, digit_buffer, output, true)
      }
      MenuDown => {
        digit_buffer = ""
        selected = if selected + 1 >= total_choices { 0 } else { selected + 1 }
        render_provider_kind_menu(kinds, selected, digit_buffer, output, true)
      }
      MenuDigit(digit) => {
        let (next_selected, next_buffer) = update_digit_buffer(
          digit_buffer,
          digit,
          kinds.length(),
          selected,
        )
        selected = next_selected
        digit_buffer = next_buffer
        render_provider_kind_menu(kinds, selected, digit_buffer, output, true)
      }
      MenuBackspace => {
        let (next_selected, next_buffer) = remove_digit_buffer(
          digit_buffer,
          kinds.length(),
          selected,
        )
        selected = next_selected
        digit_buffer = next_buffer
        render_provider_kind_menu(kinds, selected, digit_buffer, output, true)
      }
      MenuEnter => {
        output.write("\r\u001b[\{total_lines - 1}A\u001b[J")
        if selected == kinds.length() {
          return CancelKind
        }
        return SelectKind(kinds[selected])
      }
      MenuBack => ()
      MenuIgnore => ()
    }
  } nobreak {
    cli_error("selection loop terminated unexpectedly")
  }
}

///|
async fn prompt_for_provider_line_mode(
  providers : Array[Provider],
  input : &@io.Reader,
  output : &@io.Writer,
  can_go_back : Bool,
) -> ProviderChoice raise {
  let provider_names = providers.map(provider => provider.name)
  if provider_names.is_empty() {
    cli_error("the provider source does not define any selectable providers")
  }
  output.write("Available providers:\n")
  for i = 0; i < provider_names.length(); i = i + 1 {
    output.write("  \{i + 1}. \{provider_label(providers[i])}\n")
  }
  if can_go_back {
    output.write("  b. Back to client selection\n")
  }
  output.write("  0. Exit without changes\n")
  let prompt_text = if can_go_back {
    "Select provider [0-\{provider_names.length()}/b or name]: "
  } else {
    "Select provider [0-\{provider_names.length()} or name]: "
  }
  while true {
    output.write(prompt_text)
    guard input.read_until("\n") is Some(line) else {
      cli_error("selection input ended before a provider was chosen")
    }
    let trimmed = line.trim(char_set=" \t\r\n").to_string()
    if can_go_back && (trimmed == "b" || trimmed == "back") {
      return Back
    }
    match parse_selection(provider_names, line) {
      Some(choice) => return choice
      None => {
        output.write(
          "Invalid selection. Enter 0-\{provider_names.length()}, an exact provider name, or `q`: ",
        )
      }
    }
  } nobreak {
    cli_error("selection loop terminated unexpectedly")
  }
}

///|
async fn prompt_for_provider_with_cursor(
  providers : Array[Provider],
  input : &@io.Reader,
  output : &@io.Writer,
  can_go_back : Bool,
) -> ProviderChoice raise {
  if providers.is_empty() {
    cli_error("the provider source does not define any selectable providers")
  }
  output.write("\u001b[?25l")
  let back_index = providers.length()
  let exit_index = if can_go_back { providers.length() + 1 } else { providers.length() }
  let total_choices = exit_index + 1
  let total_lines = providers.length() + (if can_go_back { 5 } else { 4 })
  let mut selected = 0
  let mut digit_buffer = ""
  render_provider_menu(providers, selected, digit_buffer, output, false, can_go_back)
  while true {
    match read_menu_action(input) {
      MenuUp => {
        digit_buffer = ""
        selected = if selected == 0 { total_choices - 1 } else { selected - 1 }
        render_provider_menu(providers, selected, digit_buffer, output, true, can_go_back)
      }
      MenuDown => {
        digit_buffer = ""
        selected = if selected + 1 >= total_choices { 0 } else { selected + 1 }
        render_provider_menu(providers, selected, digit_buffer, output, true, can_go_back)
      }
      MenuBack => {
        if can_go_back {
          output.write("\r\u001b[\{total_lines - 1}A\u001b[J")
          return Back
        }
        ()
      }
      MenuDigit(digit) => {
        let (next_selected, next_buffer) = update_digit_buffer(
          digit_buffer,
          digit,
          exit_index,
          selected,
        )
        selected = next_selected
        digit_buffer = next_buffer
        render_provider_menu(providers, selected, digit_buffer, output, true, can_go_back)
      }
      MenuBackspace => {
        let (next_selected, next_buffer) = remove_digit_buffer(
          digit_buffer,
          exit_index,
          selected,
        )
        selected = next_selected
        digit_buffer = next_buffer
        render_provider_menu(providers, selected, digit_buffer, output, true, can_go_back)
      }
      MenuEnter => {
        output.write("\r\u001b[\{total_lines - 1}A\u001b[J")
        if selected == exit_index {
          return Cancel
        }
        if can_go_back && selected == back_index {
          return Back
        }
        output.write("Selected provider: \{provider_label(providers[selected])}\n")
        return Select(providers[selected].name)
      }
      MenuIgnore => ()
    }
  } nobreak {
    cli_error("selection loop terminated unexpectedly")
  }
}

///|
priv enum MenuAction {
  MenuUp
  MenuDown
  MenuDigit(Int)
  MenuBackspace
  MenuEnter
  MenuBack
  MenuIgnore
}

///|
async fn read_menu_action(input : &@io.Reader) -> MenuAction raise {
  let first = input.read_exactly(1) catch {
    _ => cli_error("selection input ended before a provider was chosen")
  }
  match first[0] {
    b'\r' | b'\n' => MenuEnter
    b'k' | b'K' => MenuUp
    b'j' | b'J' => MenuDown
    b'b' | b'B' => MenuBack
    b'\x7f' | b'\x08' => MenuBackspace
    b'0'..=b'9' => MenuDigit(first[0].to_int() - b'0'.to_int())
    b'\x1b' => {
      let escape = @async.with_timeout_opt(20, () => input.read_exactly(2))
      match escape {
        Some(seq) if seq.length() == 2 && seq[0] == b'[' && seq[1] == b'A' =>
          MenuUp
        Some(seq) if seq.length() == 2 && seq[0] == b'[' && seq[1] == b'B' =>
          MenuDown
        _ => MenuIgnore
      }
    }
    _ => MenuIgnore
  }
}

///|
async fn try_enable_raw_mode() -> String? raise {
  let (code, output) = @process.collect_stdout("stty", ["-g"])
  if code != 0 {
    return None
  }
  let snapshot = output.text().trim(char_set=" \t\r\n").to_string() catch {
    _ => return None
  }
  guard !snapshot.is_empty() else {
    return None
  }
  let set_raw_code = @process.run("stty", ["-echo", "-icanon", "min", "1", "time", "0"])
  if set_raw_code != 0 {
    return None
  }
  Some(snapshot)
}

///|
async fn restore_terminal(snapshot : String, output : &@io.Writer) -> Unit raise {
  let restore_code = @process.run("stty", [snapshot])
  if restore_code != 0 {
    ignore(@process.run("stty", ["sane"]))
  }
  output.write("\u001b[?25h")
}

///|
async fn render_provider_menu(
  providers : Array[Provider],
  selected : Int,
  digit_buffer : String,
  output : &@io.Writer,
  redraw : Bool,
  can_go_back : Bool,
) -> Unit raise {
  let extra_lines = if can_go_back { 1 } else { 0 }
  if redraw {
    output.write("\r\u001b[\{providers.length() + 3 + extra_lines}A\u001b[J")
  }
  output.write("Available providers:\n")
  for i = 0; i < providers.length(); i = i + 1 {
    let prefix = if i == selected { "> " } else { "  " }
    output.write("\u001b[2K\{prefix}\{i + 1}. \{provider_label(providers[i])}\n")
  }
  if can_go_back {
    let back_prefix = if selected == providers.length() { "> " } else { "  " }
    output.write("\u001b[2K\{back_prefix}← Back to client selection\n")
  }
  let exit_index = if can_go_back { providers.length() + 1 } else { providers.length() }
  let cancel_prefix = if selected == exit_index { "> " } else { "  " }
  output.write("\u001b[2K\{cancel_prefix}0. Exit without changes\n")
  let hint = if can_go_back {
    "Use ↑/↓, j/k, b=back, number + Enter, or 0 to exit\n"
  } else {
    "Use ↑/↓, j/k, number + Enter, or 0 to exit\n"
  }
  output.write("\u001b[2K\{hint}")
  let typed_number = if digit_buffer.is_empty() {
    "-"
  } else {
    digit_buffer
  }
  output.write("\u001b[2KTyped number: \{typed_number}")
}

///|
async fn render_provider_kind_menu(
  kinds : Array[ProviderKind],
  selected : Int,
  digit_buffer : String,
  output : &@io.Writer,
  redraw : Bool,
) -> Unit raise {
  if redraw {
    output.write("\r\u001b[\{kinds.length() + 3}A\u001b[J")
  }
  output.write("Available clients:\n")
  for i = 0; i < kinds.length(); i = i + 1 {
    let prefix = if i == selected { "> " } else { "  " }
    output.write("\u001b[2K\{prefix}\{i + 1}. \{provider_kind_title(kinds[i])}\n")
  }
  let cancel_prefix = if selected == kinds.length() { "> " } else { "  " }
  output.write("\u001b[2K\{cancel_prefix}0. Exit without changes\n")
  output.write("\u001b[2KUse ↑/↓, j/k, number + Enter, or 0 to exit\n")
  let typed_number = if digit_buffer.is_empty() {
    "-"
  } else {
    digit_buffer
  }
  output.write("\u001b[2KTyped number: \{typed_number}")
}

///|
fn update_digit_buffer(
  current : String,
  digit : Int,
  provider_count : Int,
  current_selected : Int,
) -> (Int, String) {
  let candidate = current + digit.to_string()
  match resolve_number_selection(candidate, provider_count) {
    Some(selected) => (selected, candidate)
    None => {
      let fallback = digit.to_string()
      match resolve_number_selection(fallback, provider_count) {
        Some(selected) => (selected, fallback)
        None => (current_selected, current)
      }
    }
  }
}

///|
fn remove_digit_buffer(
  current : String,
  provider_count : Int,
  current_selected : Int,
) -> (Int, String) {
  if current.is_empty() {
    return (current_selected, current)
  }
  let next = current[:current.length() - 1].to_string()
  if next.is_empty() {
    return (current_selected, next)
  }
  match resolve_number_selection(next, provider_count) {
    Some(selected) => (selected, next)
    None => (current_selected, next)
  }
}

///|
fn resolve_number_selection(raw : String, provider_count : Int) -> Int? {
  let parsed = try? @string.parse_int(raw)
  match parsed {
    Ok(number) if number == 0 => Some(provider_count)
    Ok(number) if number >= 1 && number <= provider_count => Some(number - 1)
    _ => None
  }
}

///|
fn find_provider(
  providers : Array[Provider],
  name : String,
) -> Provider raise CliError {
  for provider in providers {
    if provider.name == name {
      return provider
    }
  }
  cli_error("provider `\{name}` was not found")
}

///|
async fn load_providers(path : String) -> Array[Provider] raise {
  guard @fs.exists(path) else {
    cli_error("source file does not exist")
  }
  let text = @fs.read_file(path).text() catch {
    err => cli_error("failed to read source file as UTF-8: \{err}")
  }
  let root = @toml.parse(text) catch {
    err => cli_error("invalid TOML: \{err}")
  }
  parse_providers_doc(root)
}

///|
fn parse_providers_doc(root : @toml.TomlValue) -> Array[Provider] raise CliError {
  let root_table = expect_toml_table(root, "root")
  let providers : Array[Provider] = []
  let seen_names : Map[String, Bool] = Map::new()
  let mut found_provider_groups = false

  match root_table.get("codex") {
    Some(codex_value) => {
      found_provider_groups = true
      append_codex_providers(codex_value, providers, seen_names)
    }
    None => ()
  }
  match root_table.get("claude") {
    Some(claude_value) => {
      found_provider_groups = true
      append_claude_providers(claude_value, providers, seen_names)
    }
    None => ()
  }

  guard found_provider_groups else {
    cli_error("source file must contain [[codex]] or [[claude]] entries")
  }
  if providers.is_empty() {
    cli_error("source file does not define any providers")
  }
  providers
}

///|
fn append_codex_providers(
  value : @toml.TomlValue,
  providers : Array[Provider],
  seen_names : Map[String, Bool],
) -> Unit raise CliError {
  let provider_items = expect_toml_array(value, "codex")
  for i = 0; i < provider_items.length(); i = i + 1 {
    let prefix = "codex[\{i}]"
    let provider_table = expect_toml_table(provider_items[i], prefix)
    let provider = parse_codex_provider(provider_table, prefix)
    ensure_unique_provider_name(provider.name, seen_names)
    providers.push(provider)
  }
}

///|
fn append_claude_providers(
  value : @toml.TomlValue,
  providers : Array[Provider],
  seen_names : Map[String, Bool],
) -> Unit raise CliError {
  let provider_items = expect_toml_array(value, "claude")
  for i = 0; i < provider_items.length(); i = i + 1 {
    let prefix = "claude[\{i}]"
    let provider_table = expect_toml_table(provider_items[i], prefix)
    let provider = parse_claude_provider(provider_table, prefix)
    ensure_unique_provider_name(provider.name, seen_names)
    providers.push(provider)
  }
}

///|
fn parse_codex_provider(
  provider_table : Map[String, @toml.TomlValue],
  prefix : String,
) -> Provider raise CliError {
  for key, _ in provider_table {
    if key != "name" && key != "base_url" && key != "api_key" {
      cli_error("\{prefix} contains unsupported key `\{key}`")
    }
  }
  let name = expect_required_toml_string(provider_table, "name", prefix)
  let base_url = expect_required_toml_string(provider_table, "base_url", prefix)
  let api_key = expect_required_toml_string(provider_table, "api_key", prefix)
  let claude_env : Map[String, String] = Map::new()
  { kind: Codex, name, base_url, api_key, claude_env }
}

///|
fn parse_claude_provider(
  provider_table : Map[String, @toml.TomlValue],
  prefix : String,
) -> Provider raise CliError {
  let name = expect_required_toml_string(provider_table, "name", prefix)
  let base_url = expect_required_toml_string(provider_table, "base_url", prefix)
  let api_key = expect_required_toml_string(provider_table, "api_key", prefix)
  let claude_env : Map[String, String] = Map::new(capacity=provider_table.length())
  for key, value in provider_table {
    if key == "name" || key == "base_url" || key == "api_key" {
      continue
    }
    if key == "ANTHROPIC_BASE_URL" {
      cli_error("\{prefix}.ANTHROPIC_BASE_URL is derived from `base_url`")
    }
    if key == "ANTHROPIC_AUTH_TOKEN" {
      cli_error("\{prefix}.ANTHROPIC_AUTH_TOKEN is derived from `api_key`")
    }
    guard value is @toml.TomlString(string) else {
      cli_error("\{prefix}.\{key} must be a string")
    }
    claude_env[key] = string
  }
  { kind: Claude, name, base_url, api_key, claude_env }
}

///|
fn ensure_unique_provider_name(
  name : String,
  seen_names : Map[String, Bool],
) -> Unit raise CliError {
  guard !seen_names.contains(name) else {
    cli_error("duplicate provider name `\{name}`")
  }
  seen_names[name] = true
}

///|
fn expect_toml_array(
  value : @toml.TomlValue,
  path : String,
) -> Array[@toml.TomlValue] raise CliError {
  guard value is @toml.TomlArray(array) else {
    cli_error("\{path} must be an array of tables")
  }
  array
}

///|
fn expect_toml_table(
  value : @toml.TomlValue,
  path : String,
) -> Map[String, @toml.TomlValue] raise CliError {
  guard value is @toml.TomlTable(table) else {
    cli_error("\{path} must be a TOML table")
  }
  table
}

///|
fn expect_required_toml_string(
  table : Map[String, @toml.TomlValue],
  key : String,
  prefix : String,
) -> String raise CliError {
  guard table.get(key) is Some(value) else {
    cli_error("\{prefix} must contain `\{key}`")
  }
  guard value is @toml.TomlString(string) else {
    cli_error("\{prefix}.\{key} must be a string")
  }
  guard !string.trim(char_set=" \t\r\n").is_empty() else {
    cli_error("\{prefix}.\{key} must not be empty")
  }
  string
}

///|
fn copy_toml(value : @toml.TomlValue) -> @toml.TomlValue {
  match value {
    @toml.TomlString(string) => @toml.TomlString(string)
    @toml.TomlInteger(integer) => @toml.TomlInteger(integer)
    @toml.TomlFloat(float) => @toml.TomlFloat(float)
    @toml.TomlBoolean(boolean) => @toml.TomlBoolean(boolean)
    @toml.TomlDateTime(datetime) => @toml.TomlDateTime(datetime)
    @toml.TomlArray(array) => @toml.TomlArray(array.map(copy_toml))
    @toml.TomlTable(table) => {
      let copied : Map[String, @toml.TomlValue] = Map::new(capacity=table.length())
      for key, item in table {
        copied[key] = copy_toml(item)
      }
      @toml.TomlTable(copied)
    }
  }
}

///|
fn copy_json(value : Json) -> Json {
  match value {
    Null => Json::null()
    True => Json::boolean(true)
    False => Json::boolean(false)
    Number(number, repr~) => Json::number(number, repr?)
    String(string) => Json::string(string)
    Array(array) => Json::array(array.map(copy_json))
    Object(object) => {
      let copied : Map[String, Json] = Map::new(capacity=object.length())
      for key, item in object {
        copied[key] = copy_json(item)
      }
      Json::object(copied)
    }
  }
}

///|
fn build_updated_config(
  current_config : @toml.TomlValue,
  provider : Provider,
) -> @toml.TomlValue raise CliError {
  let root = expect_toml_table(copy_toml(current_config), "config root")
  root["model_provider"] = @toml.TomlString(provider.name)

  match root.get("model_providers") {
    Some(@toml.TomlTable(_)) => ()
    Some(_) => cli_error("config root field `model_providers` must be a table")
    None => ()
  }
  let provider_tables : Map[String, @toml.TomlValue] = Map::new()
  root["model_providers"] = @toml.TomlTable(provider_tables)
  let selected_provider_table : Map[String, @toml.TomlValue] = Map::new()
  provider_tables[provider.name] = @toml.TomlTable(selected_provider_table)
  selected_provider_table["name"] = @toml.TomlString(provider.name)
  selected_provider_table["base_url"] = @toml.TomlString(provider.base_url)

  @toml.TomlTable(root)
}

///|
fn build_updated_claude_settings(
  current_settings : Json,
  provider : Provider,
) -> Json raise CliError {
  guard provider.kind is Claude else {
    cli_error("internal error: expected a Claude provider")
  }
  match copy_json(current_settings) {
    Object(object) => {
      let env : Map[String, Json] = Map::new(capacity=provider.claude_env.length() + 2)
      env["ANTHROPIC_BASE_URL"] = Json::string(provider.base_url)
      env["ANTHROPIC_AUTH_TOKEN"] = Json::string(provider.api_key)
      for key, value in provider.claude_env {
        env[key] = Json::string(value)
      }
      object["env"] = Json::object(env)
      Json::object(object)
    }
    _ => cli_error("claude settings target must contain a JSON object at the root")
  }
}

///|
fn build_updated_auth(current_auth : Json, provider : Provider) -> Json raise CliError {
  match copy_json(current_auth) {
    Object(object) => {
      object["OPENAI_API_KEY"] = Json::string(provider.api_key)
      Json::object(object)
    }
    _ => cli_error("auth target must contain a JSON object at the root")
  }
}

///|
fn escape_toml_basic_string(s : String) -> String {
  let result = StringBuilder::new()
  for char in s {
    match char {
      '\b' => result.write_string("\\b")
      '\t' => result.write_string("\\t")
      '\n' => result.write_string("\\n")
      '\f' => result.write_string("\\f")
      '\r' => result.write_string("\\r")
      '"' => result.write_string("\\\"")
      '\\' => result.write_string("\\\\")
      c if c >= '\u0000' && c <= '\u001F' => {
        result.write_string("\\u")
        let code = c.to_int()
        let hex = StringBuilder::new()
        for i = 3; i >= 0; i = i - 1 {
          let digit = (code >> (i * 4)) & 0xF
          if digit < 10 {
            hex.write_char(Int::unsafe_to_char('0'.to_int() + digit))
          } else {
            hex.write_char(Int::unsafe_to_char('A'.to_int() + digit - 10))
          }
        }
        result.write_string(hex.to_string())
      }
      '\u007F' => result.write_string("\\u007F")
      c => result.write_char(c)
    }
  }
  result.to_string()
}

///|
fn needs_toml_key_quotes(key : String) -> Bool {
  if key.is_empty() {
    return true
  }
  if key is [' ' | '\t', ..] || key is [.., ' ' | '\t'] {
    return true
  }
  for char in key {
    match char {
      'a'..='z' | 'A'..='Z' | '0'..='9' | '_' | '-' => continue
      _ => return true
    }
  }
  false
}

///|
fn format_toml_key(key : String) -> String {
  if needs_toml_key_quotes(key) {
    "\"\{escape_toml_basic_string(key)}\""
  } else {
    key
  }
}

///|
fn should_format_toml_array_inline(arr : Array[@toml.TomlValue]) -> Bool {
  if arr.is_empty() || arr.length() > 5 {
    return arr.is_empty()
  }
  for value in arr {
    match value {
      @toml.TomlTable(_) => return false
      @toml.TomlArray(inner) if !should_format_toml_array_inline(inner) => return false
      _ => continue
    }
  }
  true
}

///|
fn serialize_config_toml(value : @toml.TomlValue) -> String raise CliError {
  ignore(expect_toml_table(value, "config root"))
  let output = StringBuilder::new()
  write_config_toml(value, output, [])
  output.to_string()
}

///|
fn write_config_toml(
  value : @toml.TomlValue,
  output : StringBuilder,
  path : Array[String],
) -> Unit {
  match value {
    @toml.TomlString(string) =>
      output.write_string("\"\{escape_toml_basic_string(string)}\"")
    @toml.TomlInteger(integer) => output.write_string(integer.to_string())
    @toml.TomlFloat(float) =>
      if float.is_nan() {
        output.write_string("nan")
      } else if float.is_inf() {
        output.write_string(if float < 0.0 { "-inf" } else { "inf" })
      } else {
        let rendered = float.to_string()
        if !rendered.contains(".") && !rendered.contains("e") &&
          !rendered.contains("E") {
          output.write_string(rendered + ".0")
        } else {
          output.write_string(rendered)
        }
      }
    @toml.TomlBoolean(boolean) =>
      output.write_string(if boolean { "true" } else { "false" })
    @toml.TomlDateTime(datetime) =>
      output.write_string(@toml.TomlDateTime(datetime).to_string())
    @toml.TomlArray(array) =>
      if should_format_toml_array_inline(array) {
        output.write_string("[")
        for i = 0; i < array.length(); i = i + 1 {
          if i > 0 {
            output.write_string(", ")
          }
          write_config_toml(array[i], output, path)
        }
        output.write_string("]")
      } else {
        output.write_string("[\n")
        for i = 0; i < array.length(); i = i + 1 {
          output.write_string("  ")
          write_config_toml(array[i], output, path)
          if i < array.length() - 1 {
            output.write_string(",")
          }
          output.write_string("\n")
        }
        output.write_string("]")
      }
    @toml.TomlTable(table) =>
      if path.is_empty() {
        write_config_table_contents(table, output, path)
      } else {
        write_config_inline_table(table, output)
      }
  }
}

///|
fn write_config_table_contents(
  table : Map[String, @toml.TomlValue],
  output : StringBuilder,
  path : Array[String],
) -> Unit {
  let simple_pairs : Array[(String, @toml.TomlValue)] = []
  let array_pairs : Array[(String, @toml.TomlValue)] = []
  let table_pairs : Array[(String, @toml.TomlValue)] = []

  for key, value in table {
    match value {
      @toml.TomlTable(_) => table_pairs.push((key, value))
      @toml.TomlArray(array) => {
        let mut is_table_array = true
        for item in array {
          match item {
            @toml.TomlTable(_) => continue
            _ => {
              is_table_array = false
              break
            }
          }
        }
        if is_table_array && array.length() > 0 {
          table_pairs.push((key, value))
        } else {
          array_pairs.push((key, value))
        }
      }
      _ => simple_pairs.push((key, value))
    }
  }

  for i = 0; i < simple_pairs.length(); i = i + 1 {
    let (key, value) = simple_pairs[i]
    output.write_string(format_toml_key(key))
    output.write_string(" = ")
    write_config_toml(value, output, path)
    output.write_string("\n")
  }

  for i = 0; i < array_pairs.length(); i = i + 1 {
    let (key, value) = array_pairs[i]
    if i > 0 || simple_pairs.length() > 0 {
      output.write_string("\n")
    }
    output.write_string(format_toml_key(key))
    output.write_string(" = ")
    write_config_toml(value, output, path)
    output.write_string("\n")
  }

  for i = 0; i < table_pairs.length(); i = i + 1 {
    let (key, value) = table_pairs[i]
    if i > 0 || simple_pairs.length() > 0 || array_pairs.length() > 0 {
      output.write_string("\n")
    }
    match value {
      @toml.TomlArray(array) =>
        for j = 0; j < array.length(); j = j + 1 {
          if j > 0 {
            output.write_string("\n")
          }
          output.write_string("[[")
          write_config_table_path(path, output)
          if path.length() > 0 {
            output.write_string(".")
          }
          output.write_string(format_toml_key(key))
          output.write_string("]]\n")
          match array[j] {
            @toml.TomlTable(item_table) => {
              let new_path = path.copy()
              new_path.push(key)
              write_config_table_contents(item_table, output, new_path)
            }
            _ => ()
          }
        }
      @toml.TomlTable(subtable) => {
        output.write_string("[")
        write_config_table_path(path, output)
        if path.length() > 0 {
          output.write_string(".")
        }
        output.write_string(format_toml_key(key))
        output.write_string("]\n")
        let new_path = path.copy()
        new_path.push(key)
        write_config_table_contents(subtable, output, new_path)
      }
      _ => ()
    }
  }
}

///|
fn write_config_inline_table(
  table : Map[String, @toml.TomlValue],
  output : StringBuilder,
) -> Unit {
  output.write_string("{ ")
  let mut first = true
  for key, value in table {
    if !first {
      output.write_string(", ")
    }
    first = false
    output.write_string(format_toml_key(key))
    output.write_string(" = ")
    match value {
      @toml.TomlTable(subtable) => write_config_inline_table(subtable, output)
      _ => write_config_toml(value, output, [])
    }
  }
  output.write_string(" }")
}

///|
fn write_config_table_path(path : Array[String], output : StringBuilder) -> Unit {
  for i = 0; i < path.length(); i = i + 1 {
    if i > 0 {
      output.write_string(".")
    }
    output.write_string(format_toml_key(path[i]))
  }
}

///|
async fn apply_provider(
  provider : Provider,
  config_path : String,
  auth_path : String,
  claude_settings_path : String,
) -> ApplySummary raise {
  match provider.kind {
    Codex => {
      let current_config = read_config_target(config_path) catch {
        err => cli_error("\{err}")
      }
      let updated_config = build_updated_config(current_config, provider) catch {
        CliError(message) => cli_error(message)
      }
      let config_text = serialize_config_toml(updated_config) catch {
        CliError(message) => cli_error(message)
      }

      let current_auth = read_auth_target(auth_path) catch {
        err => cli_error("\{err}")
      }
      let updated_auth = build_updated_auth(current_auth, provider) catch {
        CliError(message) => cli_error(message)
      }

      ensure_parent_dir(config_path)
      @fs.write_file(config_path, config_text, create=0o600, truncate=true)
      ensure_parent_dir(auth_path)
      @fs.write_file(
        auth_path,
        updated_auth.stringify(indent=2) + "\n",
        create=0o600,
        truncate=true,
      )

      { provider_label: provider_label(provider), updated_files: [config_path, auth_path] }
    }
    Claude => {
      let current_settings = read_claude_settings_target(claude_settings_path) catch {
        err => cli_error("\{err}")
      }
      let updated_settings = build_updated_claude_settings(current_settings, provider) catch {
        CliError(message) => cli_error(message)
      }
      ensure_parent_dir(claude_settings_path)
      @fs.write_file(
        claude_settings_path,
        updated_settings.stringify(indent=2) + "\n",
        create=0o600,
        truncate=true,
      )
      { provider_label: provider_label(provider), updated_files: [claude_settings_path] }
    }
  }
}

///|
async fn read_config_target(path : String) -> @toml.TomlValue raise {
  if !@fs.exists(path) {
    return @toml.TomlTable(Map::new())
  }
  let text = @fs.read_file(path).text() catch {
    err => cli_error("failed to read config target as UTF-8: \{err}")
  }
  let parsed = @toml.parse(text) catch {
    err => cli_error("failed to parse config target: \{err}")
  }
  ignore(expect_toml_table(parsed, path))
  copy_toml(parsed)
}

///|
async fn read_auth_target(path : String) -> Json raise {
  if !@fs.exists(path) {
    return default_auth_json()
  }
  let text = @fs.read_file(path).text() catch {
    err => cli_error("failed to read auth target as UTF-8: \{err}")
  }
  let parsed = @json.parse(text) catch {
    err => cli_error("failed to parse auth target: \{err}")
  }
  guard parsed is Object(_) else {
    cli_error("auth target must contain a JSON object at the root")
  }
  copy_json(parsed)
}

///|
async fn read_claude_settings_target(path : String) -> Json raise {
  if !@fs.exists(path) {
    return default_claude_settings_json()
  }
  let text = @fs.read_file(path).text() catch {
    err => cli_error("failed to read Claude settings target as UTF-8: \{err}")
  }
  let parsed = @json.parse(text) catch {
    err => cli_error("failed to parse Claude settings target: \{err}")
  }
  guard parsed is Object(_) else {
    cli_error("claude settings target must contain a JSON object at the root")
  }
  copy_json(parsed)
}

///|
fn default_auth_json() -> Json {
  Json::object({
    "OPENAI_API_KEY": Json::null(),
  })
}

///|
fn default_claude_settings_json() -> Json {
  Json::object({})
}

///|
async fn ensure_parent_dir(path : String) -> Unit raise {
  let parent = parent_dir(path)
  if parent == "." || parent.is_empty() {
    return
  }
  if !@fs.exists(parent) {
    @fs.mkdir(parent, permission=0o700, recursive=true)
  }
}

///|
fn parent_dir(path : String) -> String {
  // Find the last path separator (both / and \)
  let mut last_sep : Int? = None
  let mut i = 0
  while i < path.length() {
    let c = path[i]
    // Compare with character codes: '/' = 47, '\\' = 92, ':' = 58
    if c == 47 || c == 92 {
      last_sep = Some(i)
    }
    i = i + 1
  }
  
  match last_sep {
    Some(0) => {
      // Root directory - check for Windows drive letter (e.g., "C:")
      if path.length() >= 2 && path[1] == 58 {
        path[:2].to_string() + "/"
      } else {
        "/"
      }
    }
    Some(index) => path[:index].to_string()
    None => "."
  }
}
