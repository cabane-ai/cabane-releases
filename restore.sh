#!/bin/sh
# Restore a backup that backup.sh took, onto a machine with no Cabane on it yet:
#
#   sh restore.sh <file>       from the folder holding compose.yaml
#   docker compose up -d
#
# It makes the volumes and fills them from the file, and puts the backup's
# `.env` beside compose.yaml when there isn't one. It never writes over a
# volume that exists: on a machine that already has this Cabane, take a backup
# of it first, then remove it with `docker compose down -v`, which erases it.
# The release here may be the backup's or a newer one; the app migrates the
# database forward when it starts.
set -eu
cd "$(dirname "$0")"
umask 077

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: sh restore.sh <backup file>" >&2
  exit 1
fi
given=$1
case "$given" in
  /*) file="$given" ;;
  *) file="$PWD/$given" ;;
esac

volumes=$(docker run --rm -v "$file:/in/backup.tar.gz:ro" postgres:17 \
  sh -c 'tar -tzf /in/backup.tar.gz | sed -n "s#^\./volumes/\([a-z_]*\)/\$#\1#p"')
case " $(echo $volumes) " in
  *" db "*) ;;
  *)
    echo "$given has no database in it. Is it a file backup.sh wrote?" >&2
    exit 1
    ;;
esac

# With no `.env` here, the backup's is the one this Cabane will start with, so its settings
# (a project name among them) decide the volumes' names. It waits beside compose.yaml, readable
# only by whoever ran this, until the restore is done.
pending=""
if [ ! -e .env ]; then
  docker run --rm -v "$file:/in/backup.tar.gz:ro" -v "$PWD:/here" postgres:17 sh -c "
    umask 077
    if tar -tzf /in/backup.tar.gz ./.env >/dev/null 2>&1; then
      tar -xzf /in/backup.tar.gz -O ./.env > /here/.env.restoring
      chown $(id -u):$(id -g) /here/.env.restoring
    fi"
  if [ -f .env.restoring ]; then pending=.env.restoring; fi
fi
discard() { if [ -n "$pending" ]; then rm -f "$pending"; fi; }

# The project name as Compose itself resolves it: the shell, then `.env`, then compose.yaml's
# `name:`. The volumes are `<project>_<volume>`.
if [ -n "$pending" ]; then
  config=$(docker compose --env-file "$pending" config --format json) || { discard; exit 1; }
else
  config=$(docker compose config --format json)
fi
project=$(printf '%s\n' "$config" | sed -n 's/^  "name": "\([^"]*\)",\{0,1\}$/\1/p' | head -n 1)
case "$project" in
  '' | *[!a-z0-9_-]*)
    echo "Couldn't read this Cabane's project name from docker compose config. Nothing was changed." >&2
    discard
    exit 1
    ;;
esac

for volume in $volumes; do
  if docker volume inspect "${project}_${volume}" >/dev/null 2>&1; then
    echo "${project}_${volume} already exists, so this machine already has a Cabane. Nothing was changed." >&2
    discard
    exit 1
  fi
done

set -- docker run --rm -v "$file:/in/backup.tar.gz:ro"
for volume in $volumes; do
  # Labelled as compose labels its own, so `docker compose up` takes them as this project's.
  docker volume create \
    --label "com.docker.compose.project=${project}" \
    --label "com.docker.compose.volume=${volume}" \
    "${project}_${volume}" >/dev/null
  set -- "$@" -v "${project}_${volume}:/restore/volumes/${volume}"
done
set -- "$@" postgres:17 tar --numeric-owner --same-permissions -xzf /in/backup.tar.gz -C /restore ./volumes
"$@"
if [ -n "$pending" ]; then
  mv "$pending" .env
  echo "Restored .env"
fi
echo "Restored" $volumes "into ${project} from $given. Start it with: docker compose up -d"
