---
name: runner-accepted-config-keys-stay-accepted
description: A config key the runner ever accepted keeps loading — it becomes an ignored, warned-about field, never an unknown-key rejection
subsystem: runner
sources: [runner/internal/config/config.go, runner/internal/config/loader_test.go, runner/connect.go, runner/doctor.go, install.sh]
updated: 2026-09-03
---

# Accepted config keys stay accepted

## Rule

The runner's loader rejects unknown keys (`KnownFields(true)`), so every key
it ever accepted is a promise to the config files already on hosts. A key that
loses its purpose stays in the struct as a field the runner reads nowhere:
`Config.IgnoredKeys` names it, `connect` warns about it at boot, and `doctor`
reports it. It is never deleted while a fielded config may still carry the
line; removal goes through the deprecation path in
`.agent/kb/specs/compatibility.md` with evidence that no supported install
still writes or carries it. `install.sh` runs the staged binary against the
host's config BEFORE the service stops, so a rejection is a refusal that
repeats the binary's own message, never a crash loop.

## Why

Runner 0.24.0 deleted `paths.work_dir` after install.sh had stopped writing it.
Every host installed before 2026-08-06 still had the line; `emisar connect`
exited 1 within 20 ms on each of them and the installer rolled back, so no
fielded runner could update. A config is written once and copied into
cloud-init templates for years — the installer skeleton of the day is not the
config of the fleet.

## Good

```go
// WorkDir is accepted and ignored: install.sh wrote it until 2026-08-06.
WorkDir string `yaml:"work_dir,omitempty"`

func (c *Config) IgnoredKeys() []string { … }
```

## Bad

```go
type Paths struct {
	DataDir string   `yaml:"data_dir"` // work_dir deleted: "nothing reads it"
	Packs   []string `yaml:"packs"`
}
```

## Sweep

Before deleting or renaming any `yaml:"…"` tag under `runner/internal/config`,
check every installer skeleton that ever wrote it (`git log -S'<key>' --
install.sh`) and extend the loader fixture `legacyInstallerConfig`.

## Enforcement

`TestLoad_AcceptsEveryKeyAnEarlierInstallerWrote` loads the 2026-08-05
installer skeleton verbatim; the installer harness check "staged binary
rejects the config" proves the pre-stop refusal.
