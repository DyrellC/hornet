#!/bin/bash

# Files that keys will be placed (keep these somewhere safe)
KEYS_FILE="./keys.txt"
INX_KEYS_FILE="./inx_keys.txt"

# If snapshots or key files exist, no need to do a snapshot (unless restarting)
if [ -d snapshots ]; then
  echo "Snapshot already exists, check files, exiting..."
  exit
fi

if [[ -f $KEYS_FILE || -f $INX_KEYS_FILE ]]; then
  echo "Keys already exist, check files, exiting..."
  exit
fi

# Create snapshot directory and give ownership to Docker
mkdir -p snapshots/tangle
if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 snapshots
fi


# Create Faucet Keys and Addresses and store the keys for the INX into the appropriate file
docker run --rm hornet:dev tool ed25519-key > $INX_KEYS_FILE
while read -r line; do
  # Extract key and address from INX_KEYS_FILE to confirm they exist
  FAUCET_PUBLIC_KEY=`echo $line | awk '{if (match($0, /Your ed25519 public key: [a-zA-Z0-9]+/)) {print $5}}'`
  FAUCET_ADDRESS=`echo $line | awk '{if (match($0, /Your bech32 address: [a-zA-Z0-9]+/)) {print $4}}'`

  if [ "$FAUCET_PUBLIC_KEY" != "" ]; then
    echo "Faucet Public Key: $FAUCET_PUBLIC_KEY"
  fi

  if [ "$FAUCET_ADDRESS" != "" ]; then
    echo "Faucet Address: $FAUCET_ADDRESS"
  fi

done < $INX_KEYS_FILE

# Create Coo Address and store the keys for the INX into the appropriate file
docker run --rm hornet:dev tool ed25519-key > $KEYS_FILE
while read -r line; do
  # Extract key and address from KEYS_FILE to confirm they exist
  PUBLIC_KEY=`echo $line | awk '{if (match($0, /Your ed25519 public key: [a-zA-Z0-9]+/)) {print $5}}'`
  ADDRESS=`echo $line | awk '{if (match($0, /Your bech32 address: [a-zA-Z0-9]+/)) {print $4}}'`

  if [ "$PUBLIC_KEY" != "" ]; then
    echo "Public Key: $PUBLIC_KEY"
  fi

  if [ "$ADDRESS" != "" ]; then
    echo "Address: $ADDRESS"
  fi

done < $KEYS_FILE


# Create a snapshot
docker run --rm \
  -v ./protocol_parameters.json:/app/protocol_parameters.json:ro \
  -v ./snapshots:/app/snapshots \
  hornet:dev tool snap-gen \
  --protocolParametersPath=/app/protocol_parameters.json \
  --mintAddress="$ADDRESS" \
  --genesisAddresses="$FAUCET_ADDRESS:1000000000000" \
  --outputPath=/app/snapshots/tangle/full_snapshot.bin