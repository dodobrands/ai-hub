# AI Hub Installation for AI Agents

If the user asked you to install AI Hub and gave you this file or its raw URL, do the installation now. Do not stop at downloading the repository. Do not report success until the setup dispatcher itself says installation is complete.

## Goal

Your job is to:

1. Get the repository onto the machine.
2. Enter the repository directory.
3. Repeatedly run `bash integrations/hub-meta/scripts/setup.sh next`.
4. Stop only when the first line of output is `STATUS: DONE`.

## Source Acquisition

This repository is public. A GitHub account is not required.

Choose a sensible install directory:

- If the current directory is empty and the user clearly wants installation "here", use it.
- Otherwise create or use a subdirectory named `ai-hub`.

### Option A: `git` is available

```bash
git clone https://github.com/dodobrands/ai-hub.git
cd ai-hub
```

If you must install into the current empty directory instead of creating `ai-hub`, this is also valid:

```bash
git clone https://github.com/dodobrands/ai-hub.git .
```

### Option B: `git` is missing

Download the zip archive over HTTPS and unpack it:

```bash
curl -L https://github.com/dodobrands/ai-hub/archive/refs/heads/main.zip -o ai-hub.zip
unzip -q ai-hub.zip
cd ai-hub-main
```

If `unzip` is unavailable, use any archive extractor available on the machine. The key requirement is to end up inside the unpacked repository root.

## Mandatory Setup Loop

Run the setup dispatcher:

```bash
bash integrations/hub-meta/scripts/setup.sh next
```

Then repeat the same command until the first output line is exactly:

```text
STATUS: DONE
```

The dispatcher prints one current step at a time. Execute that step, then call `next` again. Keep looping until done.

## Rules You Must Follow

1. Never report "installed" or "done" before `STATUS: DONE`.
2. If the dispatcher asks you to install Chrome DevTools MCP, do it automatically. Do not ask the user for permission first.
3. Prefer automatic login/session extraction when the provided scripts support it.
4. Use manual browser copy-paste fallback only when the automatic path fails.
5. Do not expose secrets in chat if the provided scripts can save them directly into `.env`.
6. Do not invent success. Base your status only on command output.

## Sensible Defaults for Optional Steps

The dispatcher may reach optional setup steps. Use these defaults unless the user explicitly asks otherwise:

- `team-config.json`: skip for now instead of blocking installation on board/channel IDs.
- `holst_login`: skip for now unless the user explicitly wants Holst immediately.
- `kaiten_token`: if the user uses Kaiten, ask for the token and validate it; otherwise let the user skip it instead of blocking the whole install.

## How to Talk to the User

Keep messages short, concrete, and action-oriented. Good examples:

- "Войди в Buildin в обычном Chrome и скажи готово."
- "Теперь Time: если уже залогинен, я сам подхвачу сессию."
- "Для Kaiten нужен API-токен из профиля. Можешь прислать его сюда или сказать 'пропустить'."

Do not explain browser storage internals, cookie extraction details, keychain internals, or similar implementation details unless the user explicitly asks.

## Completion Criteria

Installation is complete only when:

- the setup dispatcher returns `STATUS: DONE`;
- the repository is present locally;
- the agent can clearly say which optional steps were intentionally skipped.

After success, tell the user what is ready right now and mention any skipped optional steps such as `team-config.json` or Holst.

## References

- `README.md`
- `integrations/hub-meta/commands/setup.md`
