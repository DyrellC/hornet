#!/bin/bash

# Coo key files
COO_KEY1_FILE="./coo_key_1.txt"
COO_KEY2_FILE="./coo_key_2.txt"


if [ -d privatedb ]; then
  echo "database already exists, check files, exiting..."
  exit
fi

if [[ -f $COO_KEY1_FILE || -f $COO_KEY2_FILE ]]; then
  echo "Key files already exists, check files, exiting..."
  exit
fi

# Generate ed25519 private keys for coordinator
docker run --rm hornet:dev tool ed25519-key > $COO_KEY1_FILE
while read -r line; do
  priv_key=`echo $line | awk '{if (match($0, /Your ed25519 private key: [a-zA-Z0-9]+/)) {printf $5}}'`
  pub_key=`echo $line | awk '{if (match($0, /Your ed25519 public key: [a-zA-Z0-9]+/)) {printf $5}}'`

  if [[ $priv_key != "" && -z $PRIVATE_KEY1 ]]; then
    PRIVATE_KEY1=$priv_key
    echo "Private Key 1: $PRIVATE_KEY1"
  fi

  if [[ $pub_key != "" ]] && [[ -z $PUBLIC_KEY1 ]]; then
    PUBLIC_KEY1=$pub_key
    echo "Public Key 1: $PUBLIC_KEY1"
  fi

done < $COO_KEY1_FILE

docker run --rm hornet:dev tool ed25519-key > $COO_KEY2_FILE
while read -r line; do
  priv_key=`echo $line | awk '{if (match($0, /Your ed25519 private key: [a-zA-Z0-9]+/)) {printf $5}}'`
  pub_key=`echo $line | awk '{if (match($0, /Your ed25519 public key: [a-zA-Z0-9]+/)) {printf $5}}'`

  if [[ $priv_key != "" ]] && [[ -z $PRIVATE_KEY2 ]]; then
    PRIVATE_KEY2=$priv_key
    echo "Private Key 2: $PRIVATE_KEY2"
  fi

  if [[ $pub_key != "" ]] && [[ -z $PUBLIC_KEY2 ]]; then
    PUBLIC_KEY2=$pub_key
    echo "Public Key 2: $PUBLIC_KEY2"
  fi
done < $COO_KEY2_FILE


# Update public keys in config file
node update_config.js $PUBLIC_KEY1 $PUBLIC_KEY2
if [[ $? != 0 ]]; then
  echo "Failed to update configuration file, bootstrapping failed"
  exit
fi


# Set COO_PRV_KEYS variable
export COO_PRV_KEYS="$PRIVATE_KEY1,$PRIVATE_KEY2"
echo "COO_PRV_KEYS=$COO_PRV_KEYS"

# Prepare database directory for bootstrap
mkdir -p privatedb/tangle
mkdir privatedb/state
mkdir privatedb/indexer
mkdir privatedb/participation

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 privatedb
fi


# Bootstrap network (create database, genesis milestone, and coo state)
docker run --rm \
  -e COO_PRV_KEYS=$COO_PRV_KEYS \
  -v ./privatedb/tangle:/app/privatedb \
  -v ./snapshots/tangle:/app/snapshots \
  -v ./config_private_tangle.json:/app/config_private_tangle.json:ro \
  -v ./privatedb/state:/app/state \
  hornet:dev tool bootstrap-private-tangle \
  --configFile=/app/config_private_tangle.json \
  --snapshotPath=/app/snapshots/full_snapshot.bin \
  --databasePath=/app/privatedb \
  --cooStatePath=/app/state/coordinator.state