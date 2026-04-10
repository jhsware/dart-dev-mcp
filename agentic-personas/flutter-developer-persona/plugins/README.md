# Plugins Directory

This directory contains Claude Code plugins that are passed to the agent via the `--plugin-dir` CLI flag. Plugins are optional — if this directory is empty or absent, no plugin flags are added.

## How it works

When a persona is loaded, the server scans this `plugins/` directory for subdirectories. Each immediate subdirectory is treated as a separate plugin and passed as a `--plugin-dir` argument to the Claude Code CLI. For example:

```
plugins/
├── README.md          ← this file (ignored by the server)
├── my-plugin/         ← passed as --plugin-dir plugins/my-plugin
│   └── ...
└── another-plugin/    ← passed as --plugin-dir plugins/another-plugin
    └── ...
```

Only directories are picked up — files at the top level of `plugins/` (like this README) are ignored.

## Adding a plugin

1. Create a subdirectory in `plugins/` with your plugin's name
2. Add the plugin files according to the Claude Code plugin format
3. Re-zip the persona and upload it to the server

## Packaging

When creating your persona zip, include the plugins directory:

```bash
zip -r my-persona.zip persona.yaml system_prompt.md plugins/
```

The entire `plugins/` directory tree is extracted and preserved on the server when the persona is uploaded.
