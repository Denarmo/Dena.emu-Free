# Delegating coding tasks to OpenCode (DeepSeek)

The project instructions ask Claude sessions to hand routine coding work to OpenCode running
DeepSeek. This is how to do that from a Claude session on the dev PC (Windows, Git Bash).

## What is installed

- OpenCode desktop app, which ships the CLI at
  `%APPDATA%\ai.opencode.desktop\cli\<version>\opencode-cli.exe` (v2.0.30 when written).
  It is **not** on `PATH`; resolve it each time because the version folder changes on update.
- Model `opencode/deepseek-v4.1-flash-free` (OpenCode's free hosted DeepSeek V4.1 Flash).
  No API key or provider login is needed for it.
- Do **not** install the npm `opencode-ai` package: its older database schema conflicts with
  the desktop app's.

## Running a task

```bash
OC=$(ls -d /c/Users/david/AppData/Roaming/ai.opencode.desktop/cli/*/opencode-cli.exe | sort -V | tail -1)
cd /c/Users/david/Documents/GitHub/Dena.emu
timeout 600 "$OC" run -m opencode/deepseek-v4.1-flash-free "<self-contained prompt>" < /dev/null 2>&1 | tail -100
```

`run` is non-interactive: the `build` agent edits files in the current directory and exits.
Always close stdin (`< /dev/null`): with stdin left open, as in a background command, `run`
waits for input forever and never starts the task.
Use the Bash tool's `run_in_background` for anything likely to take more than ~2 minutes.
If a run fails, check the model still exists with `"$OC" models | grep -i deepseek`.

## Writing the prompt

- Name exact file paths, signatures, the style to match and what "done" means
  (e.g. "`flutter test test/foo_test.dart` passes").
- Say which files it may touch and that it must not touch others.
- Never include secrets, keys or signing material: the free tier may log prompts.
- Remind it of the clean-room rules in `CLAUDE.md` §7 (no Delta/DeltaCore, MinUI, SpruceOS,
  DuckStation or official PICO-8 source).

## After it finishes

1. Review `git diff`; revert anything out of scope.
2. Run the relevant tests/build locally.
3. Fix small issues directly; if the output is poor, do the task yourself instead of
   re-prompting repeatedly.

Good fits: boilerplate, small features, unit tests, docstrings, refactors within a few files.
Poor fits: architecture, tricky debugging, FFI/threading hot paths, security-sensitive code.
