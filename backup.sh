#!/bin/sh
# Back up this Cabane into one file: the database, the files, the secrets the
# app made on its first start, and the built-in runner's home (its pairing, its
# model logins and the agents' working folders), with `.env` if there is one.
#
#   sh backup.sh [file]        from the folder holding compose.yaml
#
# The instance stops while the copy is taken, so the database is copied at
# rest, and the services that were running start again afterwards, even if the
# copy fails. Restore it with restore.sh, on this machine or another. The file
# holds every secret the instance has, so only whoever ran this can read it,
# from the moment it is made.
set -eu
cd "$(dirname "$0")"
umask 077

# The volumes are `<project>_<volume>`, with the project name as Compose itself
# resolves it: the shell, then `.env`, then compose.yaml's `name:`.
project=$(docker compose config --format json | sed -n 's/^  "name": "\([^"]*\)",\{0,1\}$/\1/p' | head -n 1)
case "$project" in
  '' | *[!a-z0-9_-]*)
    echo "Couldn't read this Cabane's project name from docker compose config." >&2
    exit 1
    ;;
esac
file=${1:-cabane-backup-$(date -u +%Y%m%d-%H%M%S).tar.gz}
case "$file" in
  /*) ;;
  *) file="$PWD/$file" ;;
esac
if [ -e "$file" ]; then
  echo "$file already exists. Name another file." >&2
  exit 1
fi
dir=$(dirname "$file")
partial=".$(basename "$file").partial"

# The copy's `docker run`, built up as the positional arguments so a path with
# a space in it stays one argument.
set -- docker run --rm
found=""
for volume in db storage secrets companion_home; do
  if docker volume inspect "${project}_${volume}" >/dev/null 2>&1; then
    set -- "$@" -v "${project}_${volume}:/backup/volumes/${volume}:ro"
    found="$found $volume"
  fi
done
case "$found" in
  *" db"*) ;;
  *)
    echo "No Cabane database here (no ${project}_db volume). Run this from the folder holding its compose.yaml." >&2
    exit 1
    ;;
esac
if [ -f .env ]; then
  set -- "$@" -v "$PWD/.env:/backup/.env:ro"
  found="$found .env"
fi
# The database's own image does the copy: it is already on this machine.
# Numeric owners, so each volume keeps the user its container runs as. The file
# is created owner-only and then handed to whoever ran this.
set -- "$@" -v "$dir:/out" -e "PARTIAL=/out/$partial" -e "OWNER=$(id -u):$(id -g)" postgres:17 sh -c \
  'umask 077 && tar --numeric-owner -czf "$PARTIAL" -C /backup . && chown "$OWNER" "$PARTIAL"'

# What to start again afterwards: the services that are running now, of the ones this compose
# setup defines (`docker compose ps` also lists a container another compose file added).
defined=$(docker compose config --services)
running=$(docker compose ps --services --status running | grep -Fx "$defined" || true)
echo "Stopping Cabane while the copy is taken."
docker compose stop
restart() {
  if [ -n "$running" ]; then
    # shellcheck disable=SC2086 # one service name per word
    docker compose start $running
  fi
}
trap restart EXIT

"$@"
mv "$dir/$partial" "$file"
echo "Backed up${found} to $file"
