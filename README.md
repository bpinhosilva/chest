# 🔐 chest

A simple, single-file Bash script to archive (`tar.gz`), encrypt (`AES-256` via `gpg`), and restore directories on Linux.

## Requirements

Standard tools pre-installed on almost every Linux distribution:
- `bash`, `tar`, `gzip`, `gpg`

## Installation

### Option 1: Install with curl

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/bpinhosilva/chest/main/bin/chest -o ~/.local/bin/chest
chmod +x ~/.local/bin/chest
```

Make sure `~/.local/bin` is in your `$PATH`.

### Option 2: Install from a local clone

Copy the script anywhere in your `$PATH` (or run `./bin/chest` directly):

```bash
mkdir -p ~/.local/bin
cp bin/chest ~/.local/bin/chest
chmod +x ~/.local/bin/chest
```

## Usage

### 1. Create a Backup

By default, `-s` backs up `$HOME` and `-o` saves to `~/backups/<name>_YYYYmmdd_HHMMSS.tar.gz.gpg` (automatically excluding `~/backups` so old backups are never re-archived):

```bash
# Dry run: check estimated backup size in GB (after excludes) without backing up
chest backup --dry-run

# Back up your home directory ($HOME -> ~/backups)
chest backup -p "mySecretPassword"

# Back up a specific folder with verbose file-by-file output (-v)
chest backup -s ~/Documents -o ~/backups -p "mySecretPassword" -v

# Or specify an exact output file name (any -o path ending in .gpg or .enc)
chest backup -s /etc -o ~/backups/etc-backup.tar.gz.gpg -p "mySecretPassword"

# Back up encrypted to a GPG public key instead of a password (see section 4)
chest backup -s ~/Documents -o ~/backups -r you@example.com
```

- **Password prompt**: If you omit `-p`, the script prompts you interactively (with confirmation on backup) so your password won't appear in your shell history.
- **Progress & Verbose (`-v` / `--verbose`)**: By default, `chest` shows a live progress status line in the terminal and total bytes written. Pass `-v` to print every file path as it is processed.

### Unattended Runs (cron / systemd)

For scheduled backups, avoid `-p` on the command line (it leaks the password to shell history and `ps`). Two safer options:

**Environment variable:** `chest` reads `CHEST_PASSWORD` when `-p` is omitted. Keep the secret in a file only you can read and source it:

```bash
# ~/.config/chest/env  (chmod 600, owned by your user)
CHEST_PASSWORD=mySecretPassword
```

```bash
# crontab — no secret in the crontab itself
0 2 * * * . "$HOME/.config/chest/env" && chest backup
```

**GPG public key (recommended):** with `-r` the backup machine needs no secret at all — see section 4.

### Scheduling with systemd (weekly)

Sample user units are provided in [`examples/systemd/`](examples/systemd). Copy them to `~/.config/systemd/user/`, adjust the `ExecStart` line if needed, then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now chest-backup.timer

# Check it
systemctl --user list-timers chest-backup.timer
journalctl --user -u chest-backup.service
```

`Persistent=true` makes up a missed run (machine off at the scheduled time) fire at the next boot. For a root-level system timer instead, place the units in `/etc/systemd/system/` and use `systemctl` without `--user`.

### 2. Ignore Cache & Temp Directories

By default, `chest` automatically ignores common cache, temp, and virtual folders (`.cache`, `Cache`, `tmp`, `temp`, `*.tmp`, `*.swp`, `.local/share/Trash`, `node_modules`, `__pycache__`, `.venv`, `lost+found`, `/proc`, `/sys`, `/dev`, `/run`, and any directory containing a `CACHEDIR.TAG` file).

- **Ignore extra directories or patterns via CLI (`-e` / `--exclude`):**
  ```bash
  chest backup -s ~ -o ~/backups -p "mySecretPassword" -e "Downloads" -e "*.iso" -e ".steam"
  ```
- **Edit default excludes in the script:**
  Open `bin/chest` and edit the `DEFAULT_EXCLUDES` array right at the top of the file.
- **Disable default excludes:**
  ```bash
  chest backup -s ~/Documents -o ~/backups -p "mySecretPassword" --no-default-excludes
  ```

### 3. Exclude File (optional)

You can keep your exclusions in a file instead of repeating `-e` flags. The file is **optional**: `chest` looks for `~/.config/chest/excludes` and silently uses the built-in defaults if it doesn't exist. To use a file from anywhere else, pass `-E` / `--exclude-file`:

```bash
mkdir -p ~/.config/chest
cp examples/excludes ~/.config/chest/excludes

chest backup --exclude-file /path/to/my-excludes -p "mySecretPassword"
```

The file has **one pattern per line** (tar `--exclude` syntax); blank lines and lines starting with `#` are ignored:

```text
# ~/.config/chest/excludes
.cache
node_modules
Downloads
*.iso
VirtualBox VMs
```

A sample is provided in [`examples/excludes`](examples/excludes).

| Situation | Result |
|-----------|--------|
| No exclude file | Built-in default excludes are used |
| Exclude file with patterns | Those patterns **replace** the built-in defaults |
| Exclude file exists but has no patterns | No exclusions are used, and a warning is printed |
| `--exclude-file` points to a missing file | Error |

Notes:
- `-e` patterns are always added on top.
- `--no-default-excludes` disables only the built-in defaults; exclude-file and `-e` patterns still apply.
- `--no-exclude-file` ignores the exclude file entirely.
- Directories containing a `CACHEDIR.TAG` file are skipped whenever built-in defaults are enabled, even if the exclude file is empty or custom.

### 4. GPG Public-Key Encryption (optional)

Instead of a password, you can encrypt backups to a GPG **public key** with `-r` / `--recipient` (key ID, fingerprint, or email; repeatable for multiple recipients). This is ideal for unattended backups: the machine running the backup holds no secret — only the private key can decrypt.

#### Setting up the key pair

**1. Generate a dedicated backup key** (on your trusted machine, e.g. your desktop — the machine that will restore). A key used only for backups keeps your main identity key offline:

```bash
# RSA-4096 sign+encrypt key, no expiry (or set "1y" and rotate)
gpg --quick-generate-key "Backup Key <you@example.com>" rsa4096 encr4096 never
```

You'll be asked for a passphrase — this protects the private key. Choose a strong one and store it in your password manager; losing the passphrase **and** the key means losing every encrypted archive.

**2. Export both halves:**

```bash
# Public key: goes to the backup machine(s)
gpg --armor --export "you@example.com" > chest-backup-public.asc

# Private key: keep an OFFLINE copy (USB stick, encrypted vault) — never on the backup machine
gpg --armor --export-secret-keys "you@example.com" > chest-backup-private.asc
```

**3. Import on each machine:**

```bash
# On the backup machine(s): public key only
gpg --import chest-backup-public.asc

# On the restore machine: the private key
gpg --import chest-backup-private.asc
```

If a machine has several keys, `chest` targets exactly the one you name with `-r` (email, key ID, or fingerprint — `gpg --list-keys --keyid-format long` shows them).

**4. Trust the public key on the backup machine** (imported keys start untrusted; `chest` uses `--trust-model always` so encryption works regardless, but trusting avoids gpg warnings elsewhere):

```bash
echo "<FINGERPRINT>:6:" | gpg --import-ownertrust
```

**5. Protect the private key copy:** once verified, delete `chest-backup-private.asc` from disk (`shred -u chest-backup-private.asc`), keep the offline copy, and store the public key file wherever you like.

#### Key handling notes

- **Backup machine** needs only the public key — unattended and secretless.
- **Restore machine** needs the private key; gpg-agent caches its passphrase after the first decrypt of a session (`~/.gnupg/gpg-agent.conf`: `default-cache-ttl` / `max-cache-ttl` tune how long).
- **Add a second recovery recipient** by passing `-r` twice — either private key can decrypt: `chest backup ... -r you@example.com -r recovery@example.com`.
- Losing the private key means losing every key-encrypted archive — keep the offline export safe.

```bash
chest backup -s ~/Documents -o ~/backups -r you@example.com
```

- **Restore** requires the matching private key (plus its passphrase, cached by gpg-agent). The archive type is detected automatically, so restore works the same way — just omit `-p`:

```bash
chest restore -i ~/backups/Documents_20261017_153000.tar.gz.gpg -o /tmp/restored
```

- `-p` and `-r` are mutually exclusive; pick one mode per backup.

### 5. Restore a Backup

Pass the encrypted archive (`-i`), the target directory (`-o`), and the password (`-p`) if it was symmetrically encrypted, with optional `-v` for verbose file listing. The encryption type is detected automatically — public-key archives need only the private key, no `-p`:

```bash
chest restore -i ~/backups/user_20261017_153000.tar.gz.gpg -o /tmp/restored -p "mySecretPassword" -v

# Public-key archive: no password needed
chest restore -i ~/backups/user_20261017_153000.tar.gz.gpg -o /tmp/restored
```

### 6. Manual Decryption (Without `chest`)

Archives are standard `gpg` + `tar.gz` files, so you can always restore them manually on any Linux machine (for public-key archives, the private key must be in the keyring):

```bash
mkdir -p /tmp/restored
gpg -d archive.tar.gz.gpg | tar -xzpf - -C /tmp/restored
```

## Running Tests

```bash
bash tests/run_tests.sh
```
