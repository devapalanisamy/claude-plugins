# claude-plugins

Personal [Claude Code](https://code.claude.com/docs) plugins, distributed as a plugin marketplace so they sync across machines via git.

## Layout

```
.claude-plugin/marketplace.json     # marketplace manifest (lists the plugins below)
plugins/
  my-tools/
    .claude-plugin/plugin.json      # plugin manifest
    skills/
      plan-loop/SKILL.md            # the plan-loop skill
```

Add more skills under `plugins/my-tools/skills/<name>/SKILL.md` (or new plugins as sibling dirs under `plugins/`, also listed in `marketplace.json`).

## Install (first time, or on a new machine)

```
/plugin marketplace add <your-github-user>/claude-plugins
/plugin install my-tools@my-tools-marketplace
```

Installed skills are namespaced by plugin, e.g. `/my-tools:plan-loop`.

## Update after pushing changes

```
/plugin marketplace update my-tools-marketplace
/reload-plugins
```

## Plugins

### my-tools

- **plan-loop** — hybrid plan builder: clarify scope → divergent planners + judge → loop[verify-against-code + review → fix] until claims check out and reviews are clean. Args: `--planners N`, `--rounds N`, `--stop-after-clean K`, `--reviewers M`, `--no-clarify`, `--out path`.
- **dev-loop** — autonomous implement → verify (unit/integration/e2e) → code-review → fix loop until an independent review is clean. Project-agnostic: detects the stack and test commands from the repo. Args: `--effort low|medium|high|max`, `--max-loops N`.
