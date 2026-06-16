# claude-plugins

[Claude Code](https://code.claude.com/docs) plugins, distributed as a plugin marketplace so they sync across machines via git.

## Layout

```
.claude-plugin/marketplace.json     # marketplace manifest (lists the plugins below)
plugins/
  loopcraft/
    .claude-plugin/plugin.json      # plugin manifest
    hooks/
      hooks.json                    # PostToolUse lint gate (opt-in per repo)
      verify-gate.sh
    skills/
      plan-loop/SKILL.md            # the plan-loop skill
      dev-loop/SKILL.md             # the dev-loop skill
```

Add more skills under `plugins/loopcraft/skills/<name>/SKILL.md` (or new plugins as sibling dirs under `plugins/`, also listed in `marketplace.json`).

## Install (first time, or on a new machine)

```
/plugin marketplace add <your-github-user>/claude-plugins
/plugin install loopcraft@loopcraft-marketplace
```

Installed skills are namespaced by plugin, e.g. `/loopcraft:plan-loop`.

## Update after pushing changes

```
/plugin marketplace update loopcraft-marketplace
/reload-plugins
```

## Plugins

### loopcraft

Rigor-focused skills — plans grounded in real code, loops that iterate until verified-clean.

- **plan-loop** — hybrid plan builder: clarify scope → divergent planners + judge → loop[verify-against-code + review → fix] until claims check out and reviews are clean. Args: `--planners N`, `--rounds N`, `--stop-after-clean K`, `--reviewers M`, `--no-clarify`, `--out path`.
- **dev-loop** — hybrid implement loop: the main agent implements + runs live e2e (and can pause for a login), then hands the diff to a background Workflow that runs review → **consensus + cross-model adjudication** → fix → re-verify with fresh reviewers until clean; the main agent re-verifies live. Ships an opt-in `PostToolUse` lint gate (enable per repo via a `.loopcraft.json` with a `lintCommand`). Project-agnostic. Args: `--effort low|medium|high|max`, `--max-loops N`.
