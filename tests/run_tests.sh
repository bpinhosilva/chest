#!/usr/bin/env bash
# Simple test suite for chest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHEST="${SCRIPT_DIR}/../bin/chest"

BASE_TMP="${TMPDIR:-/tmp}"
[ -w "$BASE_TMP" ] || BASE_TMP="$SCRIPT_DIR"
TMP_ROOT="$(mktemp -d "${BASE_TMP}/chest_test.XXXXXX")"
export HOME="${TMP_ROOT}/home"   # isolate from the real ~/.config/chest
mkdir -p "$HOME"
export GNUPGHOME="${TMP_ROOT}/gnupg"
mkdir -m 700 "$GNUPGHOME"

cleanup() {
  gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

# 1. Syntax check
bash -n "$CHEST" && pass "Syntax check passed"

# 2. Prepare test files
SRC="${TMP_ROOT}/data"
OUT="${TMP_ROOT}/backups"
RESTORE="${TMP_ROOT}/restored"
mkdir -p "$SRC/.cache" "$SRC/tmp" "$SRC/node_modules" "$SRC/ignore_dir" "$SRC/sub"

echo "hello world" > "$SRC/file.txt"
echo "secret dotfile" > "$SRC/.env"
echo "nested file" > "$SRC/sub/notes.txt"
echo "cached" > "$SRC/.cache/junk"
echo "temp dir" > "$SRC/tmp/junk"
echo "temp file" > "$SRC/test.tmp"
echo "pkg" > "$SRC/node_modules/pkg.js"
echo "custom ignored" > "$SRC/ignore_dir/skip.txt"
echo "log file" > "$SRC/app.log"

# 3. Backup with CLI password and custom -e excludes
"$CHEST" backup -s "$SRC" -o "$OUT" -p "testpass123" -e "ignore_dir" -e "*.log"
archives=("$OUT"/data_*.tar.gz.gpg)
ARCHIVE="${archives[0]}"
[ -f "$ARCHIVE" ] && pass "Backup archive created: $(basename "$ARCHIVE")"

# 4. Restore with CLI password
"$CHEST" restore -i "$ARCHIVE" -o "$RESTORE" -p "testpass123"

# 5. Verify included files
[ "$(cat "$RESTORE/data/file.txt")" = "hello world" ] || fail "file.txt mismatch"
[ "$(cat "$RESTORE/data/.env")" = "secret dotfile" ] || fail ".env mismatch"
[ "$(cat "$RESTORE/data/sub/notes.txt")" = "nested file" ] || fail "notes.txt mismatch"
pass "Included files restored accurately"

# 6. Verify default and CLI excludes were ignored
[ ! -e "$RESTORE/data/.cache" ]       || fail ".cache should be excluded"
[ ! -e "$RESTORE/data/tmp" ]          || fail "tmp should be excluded"
[ ! -e "$RESTORE/data/test.tmp" ]     || fail "*.tmp should be excluded"
[ ! -e "$RESTORE/data/node_modules" ] || fail "node_modules should be excluded"
[ ! -e "$RESTORE/data/ignore_dir" ]   || fail "CLI -e ignore_dir should be excluded"
[ ! -e "$RESTORE/data/app.log" ]      || fail "CLI -e *.log should be excluded"
pass "Default and CLI exclusions verified"

# 7. Verify --no-default-excludes keeps cache/temp
ARCHIVE_ALL="${OUT}/all.tar.gz.gpg"
RESTORE_ALL="${TMP_ROOT}/restored_all"
"$CHEST" backup -s "$SRC" -o "$ARCHIVE_ALL" -p "testpass123" --no-default-excludes
"$CHEST" restore -i "$ARCHIVE_ALL" -o "$RESTORE_ALL" -p "testpass123"
[ -f "$RESTORE_ALL/data/.cache/junk" ] && [ -f "$RESTORE_ALL/data/test.tmp" ] || fail "--no-default-excludes failed"
pass "--no-default-excludes verified"

# 8. Verify output archive inside source directory excludes only the archive itself
ARCHIVE_INSIDE="$SRC/sub/inside.tar.gz.gpg"
RESTORE_INSIDE="${TMP_ROOT}/restored_inside"
"$CHEST" backup -s "$SRC" -o "$ARCHIVE_INSIDE" -p "testpass123"
"$CHEST" restore -i "$ARCHIVE_INSIDE" -o "$RESTORE_INSIDE" -p "testpass123"
[ "$(cat "$RESTORE_INSIDE/data/sub/notes.txt")" = "nested file" ] || fail "Sibling file in sub/ should be preserved"
[ ! -e "$RESTORE_INSIDE/data/sub/inside.tar.gz.gpg" ] || fail "Output archive inside source should be excluded"
pass "Output archive inside source directory handled properly"

# 9. Verify wrong password & missing argument handling
if "$CHEST" restore -i "$ARCHIVE" -o "${TMP_ROOT}/bad" -p "wrongpass" >/dev/null 2>&1; then
  fail "Restore with wrong password should fail"
fi
if "$CHEST" backup -s >/dev/null 2>&1; then
  fail "Missing option argument should fail"
fi
pass "Wrong password and missing option arguments rejected as expected"

# 10. Verify prompting for password when -p is omitted
ARCHIVE_PROMPT="${OUT}/prompted.tar.gz.gpg"
RESTORE_PROMPT="${TMP_ROOT}/restored_prompt"
echo "promptedpass" | "$CHEST" backup -s "$SRC" -o "$ARCHIVE_PROMPT"
echo "promptedpass" | "$CHEST" restore -i "$ARCHIVE_PROMPT" -o "$RESTORE_PROMPT"
[ "$(cat "$RESTORE_PROMPT/data/file.txt")" = "hello world" ] || fail "Prompted password backup/restore failed"
pass "Password prompt (when -p omitted) verified"

# 11. Verify --dry-run estimates size in GB without prompting for password
DRY_OUT="$("$CHEST" backup -s "$SRC" --dry-run)"
echo "$DRY_OUT" | grep -q "GB" || fail "--dry-run did not output size in GB"
pass "Dry run (--dry-run) size estimation in GB verified"

# 12. Exclude file tests
CFG_DIR="$HOME/.config/chest"
EX_DEFAULT="$CFG_DIR/excludes"
ex_restore() { # usage: ex_restore NAME [extra backup args...]; restores into $TMP_ROOT/ex_NAME
  local name="$1"; shift
  "$CHEST" backup -s "$SRC" -o "${TMP_ROOT}/ex_${name}.tar.gz.gpg" -p "testpass123" "$@" 2>"${TMP_ROOT}/ex_${name}.err"
  "$CHEST" restore -i "${TMP_ROOT}/ex_${name}.tar.gz.gpg" -o "${TMP_ROOT}/ex_${name}" -p "testpass123"
}
mkdir -p "$CFG_DIR"

# 12a. No exclude file -> defaults apply, no warning
[ ! -e "$EX_DEFAULT" ] || fail "test setup: excludes file should not exist yet"
ex_restore none
[ ! -e "${TMP_ROOT}/ex_none/data/.cache" ] && [ -f "${TMP_ROOT}/ex_none/data/file.txt" ] || fail "defaults not applied without exclude file"
! grep -q "Warning" "${TMP_ROOT}/ex_none.err" || fail "no warning expected without exclude file"
pass "Missing exclude file falls back to default excludes"

# 12b. -E from another directory; comments, blank lines, CRLF, padding, spaces in path
CUSTOM="${TMP_ROOT}/my excludes"
printf '# my excludes\n\nignore_dir\r\n  *.log  \n' > "$CUSTOM"
(cd / && ex_restore custom --exclude-file "$CUSTOM")
[ ! -e "${TMP_ROOT}/ex_custom/data/ignore_dir" ] || fail "ignore_dir not excluded via exclude file"
[ ! -e "${TMP_ROOT}/ex_custom/data/app.log" ] || fail "*.log not excluded via exclude file"
[ -d "${TMP_ROOT}/ex_custom/data/.cache" ] || fail "exclude file should replace defaults (.cache expected)"
! grep -q "Warning" "${TMP_ROOT}/ex_custom.err" || fail "unexpected warning for valid exclude file"
pass "--exclude-file reads one pattern per line from any path"

# 12c. Default location ~/.config/chest/excludes is picked up automatically
printf 'sub\n' > "$EX_DEFAULT"
ex_restore home
[ ! -e "${TMP_ROOT}/ex_home/data/sub" ] || fail "default-location exclude file not applied"
[ -d "${TMP_ROOT}/ex_home/data/.cache" ] || fail "exclude file should replace defaults"
pass "~/.config/chest/excludes is used automatically"

# 12d. CLI -e adds on top of the exclude file
ex_restore additive -e "ignore_dir"
[ ! -e "${TMP_ROOT}/ex_additive/data/sub" ] && [ ! -e "${TMP_ROOT}/ex_additive/data/ignore_dir" ] || fail "-e should add to exclude file patterns"
pass "CLI -e is additive to the exclude file"

# 12e. Exclude file without patterns (empty / comments only) -> warning, no exclusions
printf '# only comments\n\n' > "$EX_DEFAULT"
ex_restore empty
grep -q "no exclusions have been used" "${TMP_ROOT}/ex_empty.err" || fail "pattern-less exclude file should warn"
grep -q "CACHEDIR.TAG are still skipped" "${TMP_ROOT}/ex_empty.err" || fail "warning should mention CACHEDIR.TAG"
[ -d "${TMP_ROOT}/ex_empty/data/.cache" ] && [ -f "${TMP_ROOT}/ex_empty/data/test.tmp" ] || fail "pattern-less exclude file should exclude nothing"
: > "$EX_DEFAULT"
ex_restore zero
grep -q "no exclusions have been used" "${TMP_ROOT}/ex_zero.err" || fail "zero-byte exclude file should warn"
pass "Empty exclude file warns and uses no exclusions"

# 12f. --no-default-excludes keeps exclude-file patterns; without a file excludes nothing built-in
printf 'sub\n' > "$EX_DEFAULT"
ex_restore nodef --no-default-excludes
[ ! -e "${TMP_ROOT}/ex_nodef/data/sub" ] || fail "exclude file should still apply with --no-default-excludes"
rm -f "$EX_DEFAULT"
ex_restore nodef2 --no-default-excludes
[ -d "${TMP_ROOT}/ex_nodef2/data/.cache" ] || fail "built-in defaults should be disabled"
pass "--no-default-excludes only disables built-in defaults"

# 12g. --no-exclude-file ignores the exclude file
printf 'sub\n' > "$EX_DEFAULT"
ex_restore noex --no-exclude-file
[ -d "${TMP_ROOT}/ex_noex/data/sub" ] && [ ! -e "${TMP_ROOT}/ex_noex/data/.cache" ] || fail "--no-exclude-file should use built-in defaults only"
pass "--no-exclude-file ignores the exclude file"

# 12h. Explicit --exclude-file pointing to a missing file is an error
if "$CHEST" backup -s "$SRC" --dry-run --exclude-file "${TMP_ROOT}/nope" >/dev/null 2>&1; then
  fail "Missing explicit exclude file should fail"
fi
pass "Missing explicit exclude file rejected"
rm -f "$EX_DEFAULT"

# 13. Asymmetric (GPG public key) encryption via -r/--recipient
KEY_EMAIL="chest-test@example.com"
gpg --batch --passphrase '' --pinentry-mode loopback --quick-gen-key "$KEY_EMAIL" default default never >/dev/null 2>&1 \
  || fail "test setup: GPG key generation failed"
KEY_FPR="$(gpg --list-keys --with-colons "$KEY_EMAIL" | awk -F: '/^fpr:/ {print $10; exit}')"
[ -n "$KEY_FPR" ] || fail "test setup: could not read generated key fingerprint"

ARCHIVE_KEY="${OUT}/key.tar.gz.gpg"
RESTORE_KEY="${TMP_ROOT}/restored_key"
"$CHEST" backup -s "$SRC" -o "$ARCHIVE_KEY" -r "$KEY_EMAIL"
[ -f "$ARCHIVE_KEY" ] || fail "Public-key backup archive not created"
# Restore without any password: the type is auto-detected and the private key is used
"$CHEST" restore -i "$ARCHIVE_KEY" -o "$RESTORE_KEY"
[ "$(cat "$RESTORE_KEY/data/file.txt")" = "hello world" ] || fail "Public-key restore failed"
pass "Public-key encryption (-r) and passwordless auto-detected restore"

# 13b. -p and -r together are rejected
if "$CHEST" backup -s "$SRC" -o "${TMP_ROOT}/both.tar.gz.gpg" -p "x" -r "$KEY_EMAIL" >/dev/null 2>&1; then
  fail "-p and -r together should fail"
fi
pass "-p and -r mutual exclusion enforced"

# 14. CHEST_PASSWORD environment variable
ARCHIVE_ENV="${OUT}/env.tar.gz.gpg"
RESTORE_ENV="${TMP_ROOT}/restored_env"
CHEST_PASSWORD="envpass456" "$CHEST" backup -s "$SRC" -o "$ARCHIVE_ENV"
CHEST_PASSWORD="envpass456" "$CHEST" restore -i "$ARCHIVE_ENV" -o "$RESTORE_ENV"
[ "$(cat "$RESTORE_ENV/data/file.txt")" = "hello world" ] || fail "CHEST_PASSWORD backup/restore failed"
pass "CHEST_PASSWORD environment variable verified"

echo "All tests passed!"
