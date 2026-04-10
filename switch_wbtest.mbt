///|
async fn[X] with_temp_files(
  provider_text : String,
  config_text : String?,
  auth_text : String?,
  claude_settings_text : String?,
  f : async (String, String, String, String) -> X,
) -> X {
  let dir = @fs.tmpdir(prefix="moon_switch_test")
  let profiles_path = dir + "/providers.toml"
  let config_path = dir + "/config.toml"
  let auth_path = dir + "/auth.json"
  let claude_settings_path = dir + "/settings.json"
  @fs.write_file(profiles_path, provider_text, create=0o600, truncate=true)
  match config_text {
    Some(text) => @fs.write_file(config_path, text, create=0o600, truncate=true)
    None => ()
  }
  match auth_text {
    Some(text) => @fs.write_file(auth_path, text, create=0o600, truncate=true)
    None => ()
  }
  match claude_settings_text {
    Some(text) => @fs.write_file(claude_settings_path, text, create=0o600, truncate=true)
    None => ()
  }
  let result = f(profiles_path, config_path, auth_path, claude_settings_path)
  ignore(try? @fs.rmdir(dir, recursive=true))
  result
}

///|
test "parse_args accepts --profiles" {
  let parsed = parse_args(["--profiles", "providers.toml"])
  assert_eq(parsed.show_help, false)
  assert_eq(parsed.profiles_path, Some("providers.toml"))
}

///|
test "parse_selection accepts index and name" {
  let providers = ["OpenAI", "OpenRouter"]
  inspect(
    match parse_selection(providers, "1") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="select:OpenAI",
  )
  inspect(
    match parse_selection(providers, "OpenRouter") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="select:OpenRouter",
  )
  inspect(
    match parse_selection(providers, " 2 ") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="select:OpenRouter",
  )
  inspect(
    match parse_selection(providers, "missing") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="none",
  )
}

///|
test "parse_selection accepts cancel shortcuts" {
  let providers = ["OpenAI", "OpenRouter"]
  inspect(
    match parse_selection(providers, "0") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="cancel",
  )
  inspect(
    match parse_selection(providers, "q") {
      Some(Select(name)) => "select:\{name}"
      Some(Cancel) => "cancel"
      Some(Back) => "back"
      None => "none"
    },
    content="cancel",
  )
}

///|
test "available_provider_kinds returns unique kinds in menu order" {
  let providers : Array[Provider] = [
    { kind: Codex, name: "OpenAI", base_url: "https://api.openai.com/v1", api_key: "sk-1", claude_env: Map::new() },
    { kind: Codex, name: "OpenRouter", base_url: "https://openrouter.ai/api/v1", api_key: "sk-2", claude_env: Map::new() },
    { kind: Claude, name: "Baidu", base_url: "https://example.com", api_key: "token", claude_env: Map::new() },
  ]
  let kinds = available_provider_kinds(providers)
  assert_eq(kinds.length(), 2)
  assert_eq(provider_kind_label(kinds[0]), "codex")
  assert_eq(provider_kind_label(kinds[1]), "claude")
}

///|
test "parse_kind_selection accepts index and name" {
  let kinds = [Codex, Claude]
  inspect(
    match parse_kind_selection(kinds, "1") {
      Some(SelectKind(kind)) => provider_kind_title(kind)
      Some(CancelKind) => "cancel"
      None => "none"
    },
    content="Codex",
  )
  inspect(
    match parse_kind_selection(kinds, "Claude") {
      Some(SelectKind(kind)) => provider_kind_title(kind)
      Some(CancelKind) => "cancel"
      None => "none"
    },
    content="Claude",
  )
  inspect(
    match parse_kind_selection(kinds, "0") {
      Some(SelectKind(kind)) => provider_kind_title(kind)
      Some(CancelKind) => "cancel"
      None => "none"
    },
    content="cancel",
  )
}

///|
test "parse_providers_doc extracts codex and claude entries" {
  let root = @toml.parse(
    (
      #|[[codex]]
      #|name = "OpenAI"
      #|base_url = "https://api.openai.com/v1"
      #|api_key = "sk-openai"
      #|
      #|[[claude]]
      #|name = "Baidu"
      #|base_url = "https://qianfan.baidubce.com/anthropic/coding"
      #|api_key = "bce-v3/token"
      #|CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"
      #|ANTHROPIC_MODEL = "qianfan-code-latest"
      #|
    ),
  )
  let providers = parse_providers_doc(root)
  assert_eq(providers.length(), 2)
  assert_eq(provider_kind_label(providers[0].kind), "codex")
  assert_eq(providers[0].name, "OpenAI")
  assert_eq(providers[0].base_url, "https://api.openai.com/v1")
  assert_eq(providers[0].api_key, "sk-openai")
  assert_eq(provider_kind_label(providers[1].kind), "claude")
  assert_eq(providers[1].name, "Baidu")
  assert_eq(providers[1].claude_env.get("CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"), Some("1"))
  assert_eq(providers[1].claude_env.get("ANTHROPIC_MODEL"), Some("qianfan-code-latest"))
}

///|
test "parse_providers_doc rejects duplicate provider names across groups" {
  let root = @toml.parse(
    (
      #|[[codex]]
      #|name = "Shared"
      #|base_url = "https://api.openai.com/v1"
      #|api_key = "sk-1"
      #|
      #|[[claude]]
      #|name = "Shared"
      #|base_url = "https://example.com"
      #|api_key = "token"
      #|
    ),
  )
  let result = try? parse_providers_doc(root)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected duplicate provider names to fail")
  }
}

///|
test "parse_providers_doc rejects missing required fields" {
  let root = @toml.parse(
    (
      #|[[codex]]
      #|name = "OpenAI"
      #|base_url = "https://api.openai.com/v1"
      #|
    ),
  )
  let result = try? parse_providers_doc(root)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected missing api_key to fail")
  }
}

///|
test "parse_providers_doc rejects non-string claude env values" {
  let root = @toml.parse(
    (
      #|[[claude]]
      #|name = "Baidu"
      #|base_url = "https://example.com"
      #|api_key = "token"
      #|CLAUDE_CODE_ATTRIBUTION_HEADER = 0
      #|
    ),
  )
  let result = try? parse_providers_doc(root)
  match result {
    Err(_) => ()
    Ok(_) => fail("expected non-string Claude env values to fail")
  }
}

///|
async test "apply_provider updates codex config and auth and keeps only the selected provider" {
  let provider_text =
    #|[[codex]]
    #|name = "QuicklyAPI"
    #|base_url = "https://sub.jlypx.de"
    #|api_key = "sk-quick"
    #|
  let config_text =
    #|model = "gpt-5.4"
    #|model_provider = "OpenAI"
    #|
    #|[model_providers.OpenAI]
    #|name = "OpenAI"
    #|base_url = "https://api.openai.com/v1"
    #|
    #|[model_providers.QuicklyAPI]
    #|name = "QuicklyAPI"
    #|base_url = "https://old.example.com"
    #|wire_api = "responses"
    #|requires_openai_auth = true
    #|
    #|[projects."/tmp/old-project"]
    #|trust_level = "trusted"
    #|
  let auth_text =
    #|{
    #|  "auth_mode": "chatgpt",
    #|  "OPENAI_API_KEY": null,
    #|  "tokens": {
    #|    "access_token": "keep-me"
    #|  },
    #|  "last_refresh": "2026-03-31T00:00:00Z"
    #|}
  with_temp_files(provider_text, Some(config_text), Some(auth_text), None, (profiles_path, config_path, auth_path, claude_settings_path) => {
    let providers = load_providers(profiles_path)
    let summary = apply_provider(providers[0], config_path, auth_path, claude_settings_path)
    assert_eq(summary.updated_files, [config_path, auth_path])

    let config_after = read_config_target(config_path)
    @json.json_inspect(
      config_after,
      content=[
        "TomlTable",
        {
          "model": ["TomlString", "gpt-5.4"],
          "model_provider": ["TomlString", "QuicklyAPI"],
          "model_providers": [
            "TomlTable",
            {
              "QuicklyAPI": [
                "TomlTable",
                {
                  "name": ["TomlString", "QuicklyAPI"],
                  "base_url": ["TomlString", "https://sub.jlypx.de"],
                },
              ],
            },
          ],
          "projects": [
            "TomlTable",
            {
              "/tmp/old-project": ["TomlTable", { "trust_level": ["TomlString", "trusted"] }],
            },
          ],
        },
      ],
    )

    let auth_after = read_auth_target(auth_path)
    @json.json_inspect(
      auth_after,
      content={
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": "sk-quick",
        "tokens": {
          "access_token": "keep-me",
        },
        "last_refresh": "2026-03-31T00:00:00Z",
      },
    )
  })
}

///|
async test "apply_provider creates missing codex target files from minimal defaults" {
  let provider_text =
    #|[[codex]]
    #|name = "OpenRouter"
    #|base_url = "https://openrouter.ai/api/v1"
    #|api_key = "sk-router"
    #|
  with_temp_files(provider_text, None, None, None, (profiles_path, config_path, auth_path, claude_settings_path) => {
    let providers = load_providers(profiles_path)
    ignore(apply_provider(providers[0], config_path, auth_path, claude_settings_path))

    let config_after = read_config_target(config_path)
    @json.json_inspect(
      config_after,
      content=[
        "TomlTable",
        {
          "model_provider": ["TomlString", "OpenRouter"],
          "model_providers": [
            "TomlTable",
            {
              "OpenRouter": [
                "TomlTable",
                {
                  "name": ["TomlString", "OpenRouter"],
                  "base_url": ["TomlString", "https://openrouter.ai/api/v1"],
                },
              ],
            },
          ],
        },
      ],
    )

    let auth_after = read_auth_target(auth_path)
    @json.json_inspect(
      auth_after,
      content={ "OPENAI_API_KEY": "sk-router" },
    )
  })
}

///|
async test "apply_provider updates claude settings env and preserves other root fields" {
  let provider_text =
    #|[[claude]]
    #|name = "Baidu"
    #|base_url = "https://qianfan.baidubce.com/anthropic/coding"
    #|api_key = "bce-v3/token"
    #|CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"
    #|ANTHROPIC_MODEL = "qianfan-code-latest"
    #|
  let settings_text =
    #|{
    #|  "env": {
    #|    "OLD_KEY": "remove-me",
    #|    "ANTHROPIC_AUTH_TOKEN": "old-token"
    #|  },
    #|  "permissions": {
    #|    "allow": ["mcp__pencil"]
    #|  },
    #|  "model": "opus[1m]"
    #|}
  with_temp_files(provider_text, None, None, Some(settings_text), (profiles_path, config_path, auth_path, claude_settings_path) => {
    let providers = load_providers(profiles_path)
    let summary = apply_provider(providers[0], config_path, auth_path, claude_settings_path)
    assert_eq(summary.updated_files, [claude_settings_path])

    let settings_after = read_claude_settings_target(claude_settings_path)
    @json.json_inspect(
      settings_after,
      content={
        "env": {
          "ANTHROPIC_BASE_URL": "https://qianfan.baidubce.com/anthropic/coding",
          "ANTHROPIC_AUTH_TOKEN": "bce-v3/token",
          "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1",
          "ANTHROPIC_MODEL": "qianfan-code-latest"
        },
        "permissions": {
          "allow": ["mcp__pencil"]
        },
        "model": "opus[1m]"
      },
    )
  })
}

///|
async test "apply_provider creates missing claude settings from minimal defaults" {
  let provider_text =
    #|[[claude]]
    #|name = "AnyRouter"
    #|base_url = "https://anyrouter.top"
    #|api_key = "sk-claude"
    #|CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
    #|
  with_temp_files(provider_text, None, None, None, (profiles_path, config_path, auth_path, claude_settings_path) => {
    let providers = load_providers(profiles_path)
    ignore(apply_provider(providers[0], config_path, auth_path, claude_settings_path))

    let settings_after = read_claude_settings_target(claude_settings_path)
    @json.json_inspect(
      settings_after,
      content={
        "env": {
          "ANTHROPIC_BASE_URL": "https://anyrouter.top",
          "ANTHROPIC_AUTH_TOKEN": "sk-claude",
          "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"
        }
      },
    )
  })
}
