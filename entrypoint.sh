#!/usr/bin/env sh
set -x

mkdir -p /data/
cp -L /etc/secrets/*.key /data/
chown -R nginx:nginx /data

/docker-entrypoint.sh "$@"
