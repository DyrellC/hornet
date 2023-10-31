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
fi

# Check if the privatedb directory exists; if not, create it
if [ ! -d "$db_dir/coo" ]; then
  mkdir "$db_dir/coo"
fi

# Check if the snapshot directory exists; if not, create it
if [ ! -d "$snapshot_dir/autopeer" ]; then
  mkdir "$snapshot_dir/autopeer"
fi

# Check if the privatedb directory exists; if not, create it
if [ ! -d "$db_dir/autopeer" ]; then
  mkdir "$db_dir/autopeer"
fi

if [ ! -d "$db_dir/indexer" ]; then
  mkdir "$db_dir/indexer"
fi

cp -R $snapshot_dir/tangle/* $snapshot_dir/coo
cp -R $db_dir/tangle/* $db_dir/coo
cp -R $snapshot_dir/tangle/* $snapshot_dir/autopeer
cp -R $db_dir/tangle/* $db_dir/autopeer
cp -R $db_dir/tangle/* $db_dir/indexer


# Network addresses and ports
HOST="172.20.0.10"
PEER_HOST="172.20.0.11"
COO="172.20.0.20"
INDEXER="172.20.0.21"
FAUCET="172.20.0.22"
DASHBOARD="172.20.0.23"
PORT=14280
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
    echo "INX_PRIV_KEY: $INX_PRIV_KEY"
  fi
done < $INX_KEYS_FILE


# Combine private keys
export COO_PRV_KEYS="$PRIVATE_KEY1,$PRIVATE_KEY2"


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


# Check if tangle_bridge docker network overlay exists, and if it doesn't create it
if [[ -z `docker network ls -f "name=tangle_bridge" | awk 'NR==2{printf $1}'` ]]; then
  docker network create -d bridge --attachable --subnet 172.20.0.0/16 tangle_bridge
fi

echo "Starting Nodes"

echo "Peering Node"
docker run -d \
  --name peer_node \
  --network="tangle_bridge" \
  -v ./config_private_tangle_autopeering.json:/app/config_private_tangle_autopeering.json:ro \
  -v ./privatedb/autopeer:/app/privatedb \
  -v ./snapshots/autopeer:/app/snapshots \
  -v ./p2pstore:/app/p2pstore \
  --ip $PEER_HOST \
  -p $PEERING_PORT:14265/tcp \
  -p 14600:14626/udp \
  -p 15500:15600/tcp \
  -p 9450:9311/tcp \
  -p 9229:9029/tcp \
  -p 6000:6060/tcp \
  hornet:dev \
  -c config_private_tangle_autopeering.json \
  --node.alias=peer_node \
  --inx.enabled=true \
  --inx.bindAddress=$PEER_HOST:9029 > peer_node.out

echo "Coo Node"
docker run -d \
  --name coo_node \
  --network="tangle_bridge" \
  -v ./config_private_tangle.json:/app/config_private_tangle.json:ro \
  -v ./privatedb/coo:/app/privatedb \
  -v ./snapshots/coo:/app/snapshots \
  --ip $HOST \
  -p $PORT:14265/tcp \
  -p 14601:14626/udp \
  -p 15620:15600/tcp \
  -p 9350:9311/tcp \
  -p 9129:9029/tcp \
  -p 6020:6060/tcp \
  hornet:dev \
  -c config_private_tangle.json \
  --node.alias=coo_node \
  --inx.enabled=true \
  --inx.bindAddress=$HOST:9029 > coo_node.out

sleep 10

echo "Starting Coo INX"
docker run -d \
  --name coo \
  --network="tangle_bridge" \
  --ip $COO \
  -v ./privatedb/state:/app/state \
  -e COO_PRV_KEYS=$COO_PRV_KEYS \
  -p 6070:6060/tcp \
  iotaledger/inx-coordinator:1.0-rc \
  --inx.address=$HOST:9029 \
  --coordinator.stateFilePath=state/coordinator.state \
  --coordinator.blockBackups.enabled=false > coo.out

echo "Starting Indexer INX"
docker run -d \
  --name coo-indexer \
  --net "tangle_bridge" \
  -v ./$db_dir/indexer:/app/database \
  --ip $INDEXER \
  -p 9091:9091/tcp \
  iotaledger/inx-indexer:1.0-rc \
  --inx.address=$HOST:9029 \
  --restAPI.bindAddress=$INDEXER:9091 \
  --prometheus.enabled=true \
  --prometheus.bindAddress=$INDEXER:9315 \
  --prometheus.goMetrics=false \
  --prometheus.processMetrics=false \
  --prometheus.restAPIMetrics=true \
  --prometheus.inxMetrics=true \
  --prometheus.promhttpMetrics=false \
  --profiling.enabled=true \
  --profiling.bindAddress=$INDEXER:6040 > "coo-indexer.out"



echo "Starting faucet"
docker run -d \
  --name faucet \
  -e FAUCET_PRV_KEY=$INX_PRIV_KEY \
  --network "tangle_bridge" \
  -p 8091:8091/tcp \
  --ip $FAUCET \
  iotaledger/inx-faucet:1.0-rc \
  --inx.address=$HOST:9029 \
  --faucet.bindAddress=$FAUCET:8091 \
  --faucet.amount=100000000000 \
  --faucet.smallAmount=10000000000 \
  --faucet.maxAddressBalance=200000000000 \
  --faucet.rateLimit.enabled=false \
  --profiling.enabled=true \
  --profiling.bindAddress=$FAUCET:6030

    echo "Starting Coo Dashboard"
    docker run -d \
      --name coo_dashboard \
      --network "tangle_bridge"  \
      -p 8181:8081/tcp \
      --ip $DASHBOARD \
      iotaledger/inx-dashboard:1.0-rc \
      --inx.address=$HOST:9029 \
      --dashboard.bindAddress=0.0.0.0:8081 \
      --dashboard.auth.passwordHash=577eb97f8faf2af47ff957b00827d6bfe9d05b810981e3073dc42553505282c1 \
      --dashboard.auth.passwordSalt=e5d8d0bd3bb9723236177b4713a11580c55b69a51e7055dd11fa1dad3b8f6d6c \
      --prometheus.enabled=false \
      --profiling.enabled=false