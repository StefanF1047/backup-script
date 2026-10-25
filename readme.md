# backup.sh

> ⚠️ **AI-generated.** This script and documentation were produced with the
> assistance of DeepSeek-V4.1-Flash and have not been audited. Use at your own risk —
> review the code and verify a restore before trusting it with important data.

A small, safety-first shell script that backs up folders and files listed in `backup.json` to a destination of your choice.

- **Additive only** — nothing is ever deleted from the destination.
- **Verbose** — every step is timestamped and logged to `backup.log` inside the backup folder.
- **Safe by default** — validates config, refuses to run without an output folder, guards against recursion, and stops on malformed JSON.
- **Handles both folders and individual files** in the same config.

---

## Requirements

| Tool | Purpose |
|------|---------|
| `bash` (4+) | Shell |
| `jq` | Parse `backup.json` |
| `rsync` | Copy files |
| `realpath` (coreutils) | Resolve paths |

Install on common distros:

```bash
# Debian / Ubuntu
sudo apt install jq rsync coreutils

# Fedora
sudo dnf install jq rsync coreutils

# macOS (Homebrew)
brew install jq rsync coreutils
```

macOS note: the system `rsync` is old (2.6.9) and lacks `-A`/`-X`. Install the Homebrew one and make sure it's first on `PATH`, or the script will fail.

---

## Installation

Drop `backup.sh` and `backup.json` in the same directory:

```
my-backups/
├── backup.sh
└── backup.json
```

```bash
chmod +x backup.sh
```

---

## Configuration — `backup.json`

The config is a JSON object with a single `folders` key (the name is historical — it accepts files too). Its value is an **array of relative paths**, resolved against the directory containing `backup.sh`.

```json
{
  "folders": [
    "folders",
    "documents",
    "media/photos",
    "projects/my-app",
    "configs/nginx.conf",
    ".bashrc",
    ".gitconfig"
  ]
}
```

### Rules

- The top-level key **must** be `"folders"` and its value **must** be an array of strings.
- Every entry **must be a relative path** — no leading `/`. Use `documents/photos`, not `/home/me/documents/photos`. Absolute entries are skipped with a warning.
- Entries may point at a **directory** (copied recursively) or a **regular file** (copied to the same relative path in the output).
- Missing entries or paths that are neither a file nor a directory are skipped with a warning (they don't abort the run).

---

## Usage

```bash
./backup.sh <output_folder> [config_file]
```

| Argument | Description |
|----------|-------------|
| `<output_folder>` | **Required.** Where the backup is written. Created if missing. |
| `[config_file]` | Optional. Defaults to `backup.json` next to the script. |

### Examples

Back up to a dated folder:

```bash
./backup.sh /mnt/backup/$(date +%Y-%m-%d)
```

Back up to a named snapshot:

```bash
./backup.sh /mnt/backup/before-upgrade
```

Use an alternate config:

```bash
./backup.sh /mnt/backup/$(date +%Y-%m-%d) /etc/my-backup.json
```

---

## What happens on a run

1. Validates arguments, dependencies, and `backup.json` (shape and JSON validity).
2. Creates and resolves the output folder, checks it's writable.
3. Opens `<output>/backup.log` and tees all output to it.
4. For each entry in `backup.json`:
   - Rejects absolute paths.
   - Resolves the source relative to the script's directory.
   - Skips missing sources and non-file/non-directory entries with a warning.
   - Skips a directory source if the output folder lives inside it (recursion guard).
   - Runs `rsync -aHAX --ignore-existing` from source to `<output>/<relative-path>`.
5. Writes `<output>/manifest.txt` summarizing the run.
6. Prints a summary and exits with a meaningful code.

---

## Output layout

The backup mirrors your config's relative structure:

```
backup.json says:
  "folders": ["documents", "configs/nginx.conf", ".bashrc"]

/mnt/backup/2025-01-15/  (chosen output folder)
├── backup.log
├── manifest.txt
├── documents/
│   └── …               ← full recursive copy
├── configs/
│   └── nginx.conf      ← single file
└── .bashrc             ← single file
```

---

## Additive semantics

The script is designed so that **the destination only grows — nothing is ever deleted or overwritten**.

- `rsync` is invoked with **`--ignore-existing`**, so files already present at the destination are left untouched.
- There is **no `--delete`** and **no `--remove-source-files`**.

Consequences worth knowing:

- **Re-running is safe.** On a second run, existing files are skipped; only new files are added.
- **First write wins.** If a source file changes after it was backed up, re-running to the same output folder will *not* update the backup. To pick up new versions, use a fresh output folder per run (e.g. a dated one).
- If you'd rather have "update when source is newer, but still never delete," change `--ignore-existing` to `--update` — note this applies to the whole run, not per-entry.

---

## Safety features

| Feature | Behavior |
|---------|----------|
| Missing config | Exits with a message showing exactly what `backup.json` should contain. |
| Invalid JSON | Hard error before anything touches disk. |
| Missing/non-array `folders` | Hard error. |
| Empty array | Hard error. |
| No output folder argument | Prints usage and exits. |
| Output folder not writable | Hard error. |
| Absolute paths in config | Skipped with a warning. |
| Output folder inside a source | That source is skipped to prevent infinite recursion. |
| Missing sources | Skipped with a warning; other entries continue. |

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All entries succeeded (skips allowed). |
| `2` | One or more entries failed during `rsync`. |
| `1` | Setup or config error (bad args, missing deps, invalid JSON, unwritable output). |

---

## Logs and manifest

Every run writes two files into the output folder:

- **`backup.log`** — the full timestamped output of the run (tee'd live to the terminal).
- **`manifest.txt`** — date, host, config path, output path, and the list of entries attempted.

Both are append-safe: `backup.log` accumulates if you re-run into the same output folder, while `manifest.txt` is overwritten each run.
