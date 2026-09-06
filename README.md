# openclaw-lark-9x-compat

Compatibility bridge that keeps the **Feishu/Lark channel plugin** (`@larksuite/openclaw-lark`, ≤ 2026.8.5) working after upgrading **OpenClaw to 2026.9.x**.

> 中文说明见下文。[中文](#中文说明)

## The problem

OpenClaw `2026.9.1` reorganized its Plugin SDK:

- the bare `openclaw/plugin-sdk` entry point was **removed** from `package.json` `exports`
- `openclaw/plugin-sdk/channel-runtime` was **renamed/merged** into `channel-message`
- the plugin loader became stricter about module format: CJS files containing `import.meta` are now rejected

`@larksuite/openclaw-lark` (latest stable `2026.7.16`, and even the `2026.8.5-beta.0` whose published tarball is broken — `main`/`exports` point at a missing `dist/`) still relies on all three, so after upgrading OpenClaw the plugin fails to load and **every Feishu bot goes down**:

```
Error [ERR_PACKAGE_PATH_NOT_EXPORTED]: Package subpath './plugin-sdk' is not defined by "exports"
ReferenceError: exports is not defined in ES module scope
```

## The fix

`patch.sh` applies three surgical changes (idempotent, with timestamped backups):

| # | Target | Change |
|---|--------|--------|
| 1 | `openclaw/dist/plugin-sdk.js` (new file) | shim: `export * from "./plugin-sdk/core.js"` |
| 2 | `openclaw/package.json` | add `exports` entries `./plugin-sdk` → shim, `./plugin-sdk/channel-runtime` → `dist/plugin-sdk/channel-message.js` |
| 3 | installed lark plugin | rewrite `import.meta.url` → CJS `__dirname`/`__filename` in `src/core/version.js` and `src/core/token-store.js` |

No plugin features are touched — only module resolution.

## Usage

```bash
git clone https://github.com/GGlittleboy/openclaw-lark-9x-compat.git
cd openclaw-lark-9x-compat
./patch.sh                      # auto-detects the global openclaw install
openclaw gateway restart
openclaw plugins doctor         # should show no load errors
openclaw channels status        # Feishu bots should be "running"
```

If auto-detection fails, pass the package root explicitly:

```bash
./patch.sh ~/.local/opt/node-v24.19.0-linux-x64/lib/node_modules/openclaw
```

## Removal

```bash
./unpatch.sh
# then reinstall the plugin to restore its original files:
openclaw plugins install @larksuite/openclaw-lark@latest --force
openclaw gateway restart
```

## Caveats

- **An OpenClaw update wipes patch #1 and #2** (they live inside the openclaw package). Re-run `patch.sh` after each upgrade, until larksuite ships a build targeting the 2026.9 SDK.
- **A plugin reinstall/update wipes patch #3.**
- Tested: OpenClaw `2026.9.1` + `@larksuite/openclaw-lark` `2026.7.16`, Node 24.19, Linux x64.
- Once larksuite publishes a 9.x-compatible release, you don't need this repo anymore — that's the goal.

## 中文说明

OpenClaw 升级到 `2026.9.1` 后重构了插件 SDK：移除了 `openclaw/plugin-sdk` 裸入口、`channel-runtime` 子路径改名，加载器也不再容忍 CJS 文件里的 `import.meta`。飞书插件 `@larksuite/openclaw-lark`（含 stable 2026.7.16 和发行损坏的 2026.8.5-beta.0）全部中招，升级后所有飞书 bot 掉线。

本仓库的 `patch.sh` 通过三处最小改动桥接新旧接口：给 openclaw 加一个 `plugin-sdk` 垫片文件、补两条 `exports` 映射、把插件里两处 `import.meta` 改写为 CJS 写法。全部操作幂等、自动备份，验证命令见上方 Usage。

注意：每次升级 OpenClaw 后需重新执行 `patch.sh`；官方插件发布 9.x 适配版后本仓库即可退休。

## License

MIT
