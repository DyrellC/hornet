#!/bin/bash

# Key files
COO_KEY1_FILE="./coo_key_1.txt"
COO_KEY2_FILE="./coo_key_2.txt"
INX_KEYS_FILE="./inx_keys.txt"

# Storage directories
snapshot_dir="snapshots"
db_dir="privatedb"

if [[ ! -d $snapshot_dir || ! -d $db_dir ]]; then
  echo "Please generate snapshot and bootstrap first"
  exit
fi

if [[ ! -f $COO_KEY1_FILE || ! -f $COO_KEY2_FILE ]]; then
  echo "Key files don't exist, check files, exiting..."
  exit
fi

if [[ ! -f $INX_KEYS_FILE ]]; then
  echo "No inx keys for faucet found, faucet cannot be started"
  exit
fi

# Check if the snapshot directory exists; if not, create it
if [ ! -d "$snapshot_dir/coo" ]; then
  mkdir "$snapshot_dir/coo"
else
  rm "$snapshot_dir/coo/*"
fi

# Check if the privatedb directory exists; if not, create it
if [ ! -d "$db_dir/coo" ]; then
  mkdir "$db_dir/coo"
else
  rm "$db_dir/coo/*"
fi

# Check if the snapshot directory exists; if not, create it
if [ ! -d "$snapshot_dir/autopeer" ]; then
  mkdir "$snapshot_dir/autopeer"
else
  rm "$snapshot_dir/autopeer/*"
fi

# Check if the inx directories exists; if not, create them, if so, clean them out
if [ ! -d "$db_dir/autopeer" ]; then
  mkdir "$db_dir/autopeer"
else
  rm "$db_dir/autopeer/*"
fi

if [ ! -d "$db_dir/coo_state" ]; then
  mkdir "$db_dir/coo_state"
else
  rm "$db_dir/coo_state/*"
fi

if [ ! -d "$db_dir/indexer" ]; then
  mkdir "$db_dir/indexer"
else
  rm "$db_dir/indexer/*"
fi


# Copy over snapshot and db files for each resource
cp -R $snapshot_dir/tangle/* $snapshot_dir/coo
cp -R $db_dir/tangle/* $db_dir/coo

cp -R $snapshot_dir/tangle/* $snapshot_dir/autopeer
cp -R $db_dir/tangle/* $db_dir/autopeer

cp -R $db_dir/state/* $db_dir/coo_state

cp -R $db_dir/tangle/* $db_dir/indexer

# Ports to open for each node
PORT=14265
PEERING_PORT=14180


# Retrieve keys from files for coo and inx-faucet
while read -r line; do
  priv_key=`echo $line | awk '{if (match($0, /Your ed25519 private key: [a-zA-Z0-9]+/)) {printf $5}}'`

  if [[ $priv_key != "" && -z $PRIVATE_KEY1 ]]; then
    PRIVATE_KEY1=$priv_key
  fi
done < $COO_KEY1_FILE

while read -r line; do
  priv_key=`echo $line | awk '{if (match($0, /Your ed25519 private key: [a-zA-Z0-9]+/)) {printf $5}}'`

  if [[ $priv_key != "" ]] && [[ -z $PRIVATE_KEY2 ]]; then
    PRIVATE_KEY2=$priv_key
  fi
done < $COO_KEY2_FILE

while read -r line; do
  priv_key=`echo $line | awk '{if (match($0, /Your ed25519 private key: [a-zA-Z0-9]+/)) {printf $5}}'`

  if [[ $priv_key != "" ]] && [[ -z $INX_PRIV_KEY ]]; then
    INX_PRIV_KEY=$priv_key
  fi
done < $INX_KEYS_FILE


# Combine private keys
export COO_PRV_KEYS="$PRIVATE_KEY1,$PRIVATE_KEY2"
echo $COO_PRV_KEYS


# Grant ownership for docker
if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 privatedb
fi

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 snapshots
fi

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 p2pstore
fi


echo "Starting Nodes"

echo "Peering Node"
docker run -d \
  --name peer_node \
  --net host \
  -v ./config_private_tangle_autopeering.json:/app/config_private_tangle_autopeering.json:ro \
  -v ./privatedb/autopeer:/app/privatedb \
  -v ./snapshots/autopeer:/app/snapshots \
  -v ./p2pstore:/app/p2pstore \
  hornet:dev \
  -c config_private_tangle_autopeering.json \
  --node.alias=peer_node \
  --inx.enabled=true \
  --inx.bindAddress=0.0.0.0:9229 \
  --p2p.autopeering.bindAddress=0.0.0.0:14600 \
  --restAPI.bindAddress=0.0.0.0:$PEERING_PORT \
  --p2p.bindMultiAddresses="/ip4/0.0.0.0/tcp/15500","/ip6/::/tcp/15500" \
  --prometheus.bindAddress=0.0.0.0:9450 \
  --logger.level=debug \
  --profiling.bindAddress=0.0.0.0:6000 > peer_node.out

echo "Coo Node"
docker run -d \
  --name coo_node \
  --net host \
  -v ./config_private_tangle.json:/app/config_private_tangle.json:ro \
  -v ./privatedb/coo:/app/privatedb \
  -v ./snapshots/coo:/app/snapshots \
  hornet:dev \
  -c config_private_tangle.json \
  --node.alias=coo_node \
  --inx.enabled=true \
  --inx.bindAddress=0.0.0.0:9129 \
  --p2p.autopeering.bindAddress=0.0.0.0:14601 \
  --restAPI.bindAddress=0.0.0.0:$PORT \
  --p2p.bindMultiAddresses="/ip4/0.0.0.0/tcp/15501","/ip6/::/tcp/15501" \
  --prometheus.bindAddress=0.0.0.0:9350 \
  --profiling.bindAddress=0.0.0.0:6020  \
  --p2p.autopeering.entryNodes="/ip4/0.0.0.0/udp/14600/autopeering/2bPhTc5a4saVWQv7gtcRnwyYneZE2FfLZneE5PKaKwh4" > coo_node.out

sleep 5

echo "Starting Coo INX"
docker run -d \
  --name coo \
  --net host \
  -v ./privatedb/coo_state:/app/state \
  -e COO_PRV_KEYS=$COO_PRV_KEYS \
  iotaledger/inx-coordinator:1.0-rc \
  --inx.address=0.0.0.0:9129 \
  --profiling.bindAddress=0.0.0.0:6070 \
  --coordinator.stateFilePath=state/coordinator.state \
  --coordinator.blockBackups.enabled=false > coo.out


echo "Starting Indexer INX"
docker run -d \
  --name coo-indexer \
  --net host \
  -v ./$db_dir/indexer:/app/database \
  iotaledger/inx-indexer:1.0-rc \
  --inx.address=0.0.0.0:9129 \
  --restAPI.bindAddress=0.0.0.0:9091 \
  --prometheus.enabled=true \
  --prometheus.bindAddress=0.0.0.0:9315 \
  --prometheus.goMetrics=false \
  --prometheus.processMetrics=false \
  --prometheus.restAPIMetrics=true \
  --prometheus.inxMetrics=true \
  --prometheus.promhttpMetrics=false \
  --profiling.enabled=true \
  --profiling.bindAddress=0.0.0.0:6040 > "coo-indexer.out"


echo "Starting Faucet INX"
docker run -d \
  -e FAUCET_PRV_KEY=$INX_PRIV_KEY \
  --net host \
  iotaledger/inx-faucet:1.0-rc \
  --logger.level=debug \
  --inx.address=0.0.0.0:9129 \
  --faucet.bindAddress=0.0.0.0:8091 \
  --faucet.debugRequestLoggerEnabled=true \
  --faucet.amount=100000000000 \
  --faucet.smallAmount=10000000000 \
  --faucet.maxAddressBalance=200000000000 \
  --faucet.rateLimit.enabled=false \
  --profiling.enabled=true \
  --profiling.bindAddress=0.0.0.0:6030 > inx-faucet.out