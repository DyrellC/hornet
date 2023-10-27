#!/bin/bash

# Storage directories
snapshot_dir="snapshots"
db_dir="privatedb"

if [[ ! -d $snapshot_dir || ! -d $db_dir ]]; then
  echo "Please generate snapshot and bootstrap first"
  exit
fi

# Set the initial modifier value to 1
modifier=1

# Function to check if a string is a valid integer between 1 and 100
is_valid_number() {
  local num="$1"
  if [[ "$num" =~ ^[1-9][0-9]?$ || "$num" == "100" ]]; then
    return 0
  else
    return 1
  fi
}

# Check if the directory exists; if not, create it
if [ ! -d "$db_dir/tangle_1" ]; then
  mkdir -p "$db_dir/tangle_1"
else
  # Find all subdirectories that start with "tangle_" followed by a number
  dirs=$(find "$db_dir" -maxdepth 1 -type d -regex "^$db_dir/tangle_[1-9][0-9]*$")

  # Check if any matching directories were found
  if [[ -z $dirs ]]; then
    # No matching directories found, create "tangle_1"
    mkdir "$db_dir/tangle_1"
  else
    # Extract the numbers from the directory names
    numbers=()
    for d in $dirs; do
      num=$(basename "$d" | sed 's/tangle_//')
      numbers+=("$num")
    done

    # Sort the numbers in descending order
    sorted_numbers=($(echo "${numbers[@]}" | tr ' ' '\n' | sort -nr))

    # Find the highest number within the valid range (1-100)
    for num in "${sorted_numbers[@]}"; do
      if is_valid_number "$num"; then
        modifier=$((num + 1))
        break
      fi
    done

    # Create the next directory
    if is_valid_number "$modifier" && [ "$modifier" -le 100 ]; then
      mkdir "$db_dir/tangle_$modifier"
    else
      echo "No valid number found within the range (1-100)."
      exit 1
    fi
  fi
fi

node_db_dir=$db_dir/tangle_$modifier
node_snapshot_dir=$snapshot_dir/tangle_$modifier

if [ ! -d $node_db_dir ]; then
  mkdir $node_db_dir
fi

if [ ! -d $node_snapshot_dir ]; then
  mkdir $node_snapshot_dir
fi

cp -R $snapshot_dir/tangle/* $node_snapshot_dir
cp -R $db_dir/tangle/* $node_db_dir

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 $db_dir
fi

if [[ "$OSTYPE" != "darwin"* ]]; then
  chown -R 65532:65532 $snapshot_dir
fi

# Port mapping
API_PORT=$((14265+$modifier))
PEER_PORT=$((15620+$modifier))
PROMETHEUS_PORT=$((9350+$modifier))
INX_PORT=$((9130+$modifier))
INX_PEERING_PORT=$((14626+$modifier))
PROFILING_PORT=$((6020+$modifier))

HOST_END=$((30+$modifier))
HOST=172.20.0.$HOST_END

DASHBOARD_END=$((130+$modifier))
DASHBOARD_HOST=172.20.0.$DASHBOARD_END
DASHBOARD_PORT=$((8080+$modifier))

echo "Host: $HOST     API port: $API_PORT     Inx port: $INX_PEERING_PORT"

echo "Starting Node"
docker run -d \
  --name node_$modifier \
  --network="tangle_bridge" \
  -v ./config_private_tangle.json:/app/config_private_tangle.json:ro \
  -v ./$node_db_dir:/app/privatedb \
  -v ./$node_snapshot_dir:/app/snapshots \
  --ip $HOST \
  -p $API_PORT:14265/tcp \
  -p $PEER_PORT:15600/tcp \
  -p $PROMETHEUS_PORT:9311/tcp \
  -p $INX_PORT:9029/tcp \
  -p $PROFILING_PORT:6060/tcp \
  hornet:dev \
  -c config_private_tangle.json \
  --node.alias=node_$modifier \
  --inx.enabled=true \
  --inx.bindAddress=0.0.0.0:$INX_PORT \
  --p2p.autopeering.enabled=true \
  --p2p.autopeering.bindAddress=0.0.0.0:$INX_PEERING_PORT \
  --restAPI.bindAddress=0.0.0.0:$API_PORT \
  --p2p.bindMultiAddresses="/ip4/0.0.0.0/tcp/$PEER_PORT","/ip6/::/tcp/$PEER_PORT" \
  --prometheus.bindAddress=0.0.0.0:$PROMETHEUS_PORT \
  --profiling.bindAddress=0.0.0.0:$PROFILING_PORT > "node_$modifier.out"


  echo "Starting Dashboard $DASHBOARD_HOST:$DASHBOARD_PORT"
  docker run -d \
    --name dashboard_$modifier \
    --network "tangle_bridge"  \
    -p $DASHBOARD_PORT:8081/udp \
    --ip $DASHBOARD_HOST \
    dyrellc/inx-dashboard:v0.0.1 \
    --inx.address=$HOST:$INX_PORT \
    --dashboard.bindAddress=0.0.0.0:8081 \
    --dashboard.auth.passwordHash=577eb97f8faf2af47ff957b00827d6bfe9d05b810981e3073dc42553505282c1 \
    --dashboard.auth.passwordSalt=e5d8d0bd3bb9723236177b4713a11580c55b69a51e7055dd11fa1dad3b8f6d6c \
    --prometheus.enabled=false \
    --profiling.enabled=false > "dashboard_$modifier.out"