#!/bin/bash

if [[ "$OSTYPE" != "darwin"* && "$EUID" -ne 0 ]]; then
  echo "Please run as root or with sudo"
  exit
fi


# Build latest code
docker compose --profile "bootstrap" build

# Pull latest images
docker compose pull inx-coordinator
docker compose pull inx-indexer
docker compose pull inx-mqtt
docker compose pull inx-participation
docker compose pull inx-spammer
docker compose pull inx-poi
docker compose pull inx-dashboard-1
docker compose pull inx-faucet