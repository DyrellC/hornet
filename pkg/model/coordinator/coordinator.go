package coordinator

import (
	"crypto"
	"fmt"
	"os"
	"strings"
	"time"

	"crypto/ed25519"

	_ "golang.org/x/crypto/blake2b" // import implementation

	"github.com/iotaledger/hive.go/events"
	"github.com/iotaledger/hive.go/syncutils"

	"github.com/gohornet/hornet/pkg/model/hornet"
	"github.com/gohornet/hornet/pkg/model/milestone"
	"github.com/gohornet/hornet/pkg/model/tangle"
	"github.com/gohornet/hornet/pkg/pow"
	"github.com/gohornet/hornet/pkg/utils"
	"github.com/gohornet/hornet/pkg/whiteflag"
)

// BackPressureFunc is a function which tells the Coordinator
// to stop issuing milestones and checkpoints under high load.
type BackPressureFunc func() bool

// SendMessageFunc is a function which sends a message to the network.
type SendMessageFunc = func(msg *tangle.Message, isMilestone bool) error

var (
	// ErrNoTipsGiven is returned when no tips were given to issue a checkpoint.
	ErrNoTipsGiven = errors.New("no tips given")
	// ErrNetworkBootstrapped is returned when the flag for bootstrap network was given, but a state file already exists.
	ErrNetworkBootstrapped = errors.New("network already bootstrapped")
	// ErrInvalidSiblingsTrytesLength is returned when the computed siblings trytes do not fit into the signature message fragment.
	ErrInvalidSiblingsTrytesLength = errors.New("siblings trytes too long")
)

// CoordinatorEvents are the events issued by the coordinator.
type CoordinatorEvents struct {
	// Fired when a checkpoint message is issued.
	IssuedCheckpointTransaction *events.Event
	// Fired when a milestone is issued.
	IssuedMilestone *events.Event
}

// Coordinator is used to issue signed transactions, called "milestones" to secure an IOTA network and prevent double spends.
type Coordinator struct {
	milestoneLock syncutils.Mutex

	// config options
	privateKey              ed25519.PrivateKey
	minWeightMagnitude      int
	stateFilePath           string
	milestoneIntervalSec    int
	powHandler              *pow.Handler
	sendMesssageFunc        SendMessageFunc
	milestoneMerkleHashFunc crypto.Hash
	backpressureFuncs       []BackPressureFunc

	// internal state
	state        *State
	bootstrapped bool

	// events of the coordinator
	Events *CoordinatorEvents
}

// MilestoneMerkleTreeHashFuncWithName maps the passed name to one of the supported crypto.Hash hashing functions.
// Also verifies that the available function is available or else panics.
func MilestoneMerkleTreeHashFuncWithName(name string) crypto.Hash {
	//TODO: golang 1.15 will include a String() method to get the string from the crypto.Hash, so we could iterate over them instead
	var hashFunc crypto.Hash

	hashFunc.String()
	switch strings.ToLower(name) {
	case "blake2b-512":
		hashFunc = crypto.BLAKE2b_512
	case "blake2b-384":
		hashFunc = crypto.BLAKE2b_384
	case "blake2b-256":
		hashFunc = crypto.BLAKE2b_256
	case "blake2s-256":
		hashFunc = crypto.BLAKE2s_256
	default:
		panic(fmt.Sprintf("Unsupported merkle tree hash func '%s'", name))
	}

	if !hashFunc.Available() {
		panic(fmt.Sprintf("Merkle tree hash func '%s' not available. Please check the package imports", name))
	}
	return hashFunc
}

// New creates a new coordinator instance.
func New(privateKey ed25519.PrivateKey, minWeightMagnitude int, stateFilePath string, milestoneIntervalSec int, powHandler *pow.Handler, sendMessageFunc SendMessageFunc, milestoneMerkleHashFunc crypto.Hash) (*Coordinator, error) {

	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("wrong private key length")
	}

	result := &Coordinator{
		privateKey:              privateKey,
		minWeightMagnitude:      minWeightMagnitude,
		stateFilePath:           stateFilePath,
		milestoneIntervalSec:    milestoneIntervalSec,
		powHandler:              powHandler,
		sendMesssageFunc:        sendMessageFunc,
		milestoneMerkleHashFunc: milestoneMerkleHashFunc,
		Events: &CoordinatorEvents{
			IssuedCheckpointTransaction: events.NewEvent(CheckpointCaller),
			IssuedMilestone:             events.NewEvent(MilestoneCaller),
		},
	}

	return result, nil
}

// CheckPublicKey checks if the public coordinator key fits to the private key.
func (coo *Coordinator) CheckPublicKey(key string) error {

	publicKey, err := utils.ParseEd25519PublicKeyFromString(key)
	if err != nil {
		return err
	}

	if publicKey.Equal(coo.privateKey.Public()) {
		return errors.New("COO public key does not match the public key derived from the private key: %s != %s", hex.EncodeString(publicKey), hex.EncodeString(coo.privateKey.Public()))
	}

	return nil
}

// InitState loads an existing state file or bootstraps the network.
func (coo *Coordinator) InitState(bootstrap bool, startIndex milestone.Index) error {

	_, err := os.Stat(coo.stateFilePath)
	stateFileExists := !os.IsNotExist(err)

	latestMilestoneFromDatabase := tangle.SearchLatestMilestoneIndexInStore()

	if bootstrap {
		if stateFileExists {
			return ErrNetworkBootstrapped
		}

		if startIndex == 0 {
			// start with milestone 1 at least
			startIndex = 1
		}

		if latestMilestoneFromDatabase != startIndex-1 {
			return fmt.Errorf("previous milestone does not match latest milestone in database! previous: %d, database: %d", startIndex-1, latestMilestoneFromDatabase)
		}

		if startIndex == 1 {
			// if we bootstrap a network, NullHash has to be set as a solid entry point
			tangle.SolidEntryPointsAdd(hornet.NullHashBytes, startIndex)
		}

		latestMilestoneHash := hornet.NullHashBytes
		if startIndex != 1 {
			// If we don't start a new network, the last milestone has to be referenced
			cachedMilestoneMsg := tangle.GetMilestoneOrNil(latestMilestoneFromDatabase)
			if cachedMilestoneMsg == nil {
				return fmt.Errorf("latest milestone (%d) not found in database. database is corrupt", latestMilestoneFromDatabase)
			}
			latestMilestoneHash = cachedMilestoneMsg.GetMessage().GetTailHash()
			cachedMilestoneMsg.Release()
		}

		// create a new coordinator state to bootstrap the network
		state := &State{}
		state.LatestMilestoneHash = latestMilestoneHash
		state.LatestMilestoneIndex = startIndex - 1
		state.LatestMilestoneTime = 0
		state.LatestMilestoneTransactions = hornet.Hashes{hornet.NullHashBytes}

		coo.state = state
		coo.bootstrapped = false
		return nil
	}

	if !stateFileExists {
		return fmt.Errorf("state file not found: %v", coo.stateFilePath)
	}

	coo.state, err = loadStateFile(coo.stateFilePath)
	if err != nil {
		return err
	}

	if latestMilestoneFromDatabase != coo.state.LatestMilestoneIndex {
		return fmt.Errorf("previous milestone does not match latest milestone in database. previous: %d, database: %d", coo.state.LatestMilestoneIndex, latestMilestoneFromDatabase)
	}

	cachedMilestoneMsg := tangle.GetMilestoneOrNil(latestMilestoneFromDatabase)
	if cachedMilestoneMsg == nil {
		return fmt.Errorf("latest milestone (%d) not found in database. database is corrupt", latestMilestoneFromDatabase)
	}
	cachedMilestoneMsg.Release()

	coo.bootstrapped = true
	return nil
}

// createAndSendMilestone creates a milestone, sends it to the network and stores a new coordinator state file.
func (coo *Coordinator) createAndSendMilestone(trunkHash hornet.Hash, branchHash hornet.Hash, newMilestoneIndex milestone.Index) error {

	cachedMsgMetas := make(map[string]*tangle.CachedMetadata)
	cachedMessages := make(map[string]*tangle.CachedMessage)

	defer func() {
		// All releases are forced since the cone is confirmed and not needed anymore

		// release all bundles at the end
		for _, cachedMessage := range cachedMessages {
			cachedMessage.Release(true) // message -1
		}

		// Release all tx metadata at the end
		for _, cachedMsgMeta := range cachedMsgMetas {
			cachedMsgMeta.Release(true) // meta -1
		}
	}()

	// compute merkle tree root
	mutations, err := whiteflag.ComputeWhiteFlagMutations(cachedMsgMetas, cachedMessages, coo.milestoneMerkleHashFunc, trunkHash, branchHash)
	if err != nil {
		return fmt.Errorf("failed to compute muations: %w", err)
	}

	b, err := createMilestone(coo.privateKey, newMilestoneIndex, coo.securityLvl, trunkHash, branchHash, coo.minWeightMagnitude, coo.merkleTree, mutations.MerkleTreeHash, coo.powHandler)
	if err != nil {
		return fmt.Errorf("failed to create: %w", err)
	}

	if err := coo.sendMesssageFunc(b, true); err != nil {
		return err
	}

	txHashes := make(hornet.Hashes, 0, len(b))
	for i := range b {
		txHashes = append(txHashes, hornet.HashFromHashTrytes(b[i].Hash))
	}

	tailTx := &b[0]

	// always reference the last milestone directly to speed up syncing
	latestMilestoneHash := hornet.HashFromHashTrytes(tailTx.Hash)

	coo.state.LatestMilestoneHash = latestMilestoneHash
	coo.state.LatestMilestoneIndex = newMilestoneIndex
	coo.state.LatestMilestoneTime = int64(tailTx.Timestamp)
	coo.state.LatestMilestoneTransactions = txHashes

	if err := coo.state.storeStateFile(coo.stateFilePath); err != nil {
		return fmt.Errorf("failed to update state: %w", err)
	}

	coo.Events.IssuedMilestone.Trigger(coo.state.LatestMilestoneIndex, coo.state.LatestMilestoneHash)

	return nil
}

// Bootstrap creates the first milestone, if the network was not bootstrapped yet.
// Returns critical errors.
func (coo *Coordinator) Bootstrap() (hornet.Hash, error) {

	coo.milestoneLock.Lock()
	defer coo.milestoneLock.Unlock()

	if !coo.bootstrapped {
		// create first milestone to bootstrap the network
		// trunk and branch reference the last known milestone or NullHash if startIndex = 1 (see InitState)
		if err := coo.createAndSendMilestone(coo.state.LatestMilestoneHash, coo.state.LatestMilestoneHash, coo.state.LatestMilestoneIndex+1); err != nil {
			// creating milestone failed => critical error
			return nil, err
		}

		coo.bootstrapped = true
	}

	return coo.state.LatestMilestoneHash, nil
}

// IssueCheckpoint tries to create and send a "checkpoint" to the network.
// a checkpoint can contain multiple chained transactions to reference big parts of the unconfirmed cone.
// this is done to keep the confirmation rate as high as possible, even if there is an attack ongoing.
// new checkpoints always reference the last checkpoint or the last milestone if it is the first checkpoint after a new milestone.
func (coo *Coordinator) IssueCheckpoint(checkpointIndex int, lastCheckpointHash hornet.Hash, tips hornet.Hashes) (hornet.Hash, error) {

	if len(tips) == 0 {
		return nil, ErrNoTipsGiven
	}

	coo.milestoneLock.Lock()
	defer coo.milestoneLock.Unlock()

	if !tangle.IsNodeSynced() {
		return nil, tangle.ErrNodeNotSynced
	}

	// check whether we should hold issuing checkpoints
	// if the node is currently under a lot of load
	if coo.checkBackPressureFunctions() {
		return nil, tangle.ErrNodeLoadTooHigh
	}

	for i, tip := range tips {
		b, err := createCheckpoint(tip, lastCheckpointHash, coo.minWeightMagnitude, coo.powHandler)
		if err != nil {
			return nil, fmt.Errorf("failed to create: %w", err)
		}

		if err := coo.sendMesssageFunc(b, false); err != nil {
			return nil, err
		}

		lastCheckpointHash = hornet.HashFromHashTrytes(b[0].Hash)

		coo.Events.IssuedCheckpointTransaction.Trigger(checkpointIndex, i, len(tips), lastCheckpointHash)
	}

	return lastCheckpointHash, nil
}

// IssueMilestone creates the next milestone.
// Returns non-critical and critical errors.
func (coo *Coordinator) IssueMilestone(trunkHash hornet.Hash, branchHash hornet.Hash) (hornet.Hash, error, error) {

	coo.milestoneLock.Lock()
	defer coo.milestoneLock.Unlock()

	if !tangle.IsNodeSynced() {
		// return a non-critical error to not kill the database
		return nil, tangle.ErrNodeNotSynced, nil
	}

	// check whether we should hold issuing miletones
	// if the node is currently under a lot of load
	if coo.checkBackPressureFunctions() {
		return nil, tangle.ErrNodeLoadTooHigh, nil
	}

	if err := coo.createAndSendMilestone(trunkHash, branchHash, coo.state.LatestMilestoneIndex+1); err != nil {
		// creating milestone failed => critical error
		return nil, nil, err
	}

	return coo.state.LatestMilestoneHash, nil, nil
}

// GetInterval returns the interval milestones should be issued.
func (coo *Coordinator) GetInterval() time.Duration {
	return time.Second * time.Duration(coo.milestoneIntervalSec)
}

// State returns the current state of the coordinator.
func (coo *Coordinator) State() *State {
	return coo.state
}

// AddBackPressureFunc adds a BackPressureFunc.
// This function can be called multiple times to add additional BackPressureFunc.
func (coo *Coordinator) AddBackPressureFunc(bpFunc BackPressureFunc) {
	coo.backpressureFuncs = append(coo.backpressureFuncs, bpFunc)
}

// checkBackPressureFunctions checks whether any back pressure function is signaling congestion.
func (coo *Coordinator) checkBackPressureFunctions() bool {
	for _, f := range coo.backpressureFuncs {
		if f() {
			return true
		}
	}
	return false
}
