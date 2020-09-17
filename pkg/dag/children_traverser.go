package dag

import (
	"container/list"
	"sync"

	"github.com/pkg/errors"

	"github.com/gohornet/hornet/pkg/model/hornet"
	"github.com/gohornet/hornet/pkg/model/tangle"
)

type ChildrenTraverser struct {
	cachedMsgMetas map[string]*tangle.CachedMetadata

	// stack holding the ordered tx to process
	stack *list.List

	// discovers map with already found transactions
	discovered map[string]struct{}

	condition             Predicate
	consumer              Consumer
	walkAlreadyDiscovered bool
	abortSignal           <-chan struct{}

	traverserLock sync.Mutex
}

// NewChildrenTraverser create a new traverser to traverse the children (future cone)
func NewChildrenTraverser(condition Predicate, consumer Consumer, walkAlreadyDiscovered bool, abortSignal <-chan struct{}) *ChildrenTraverser {

	return &ChildrenTraverser{
		condition:             condition,
		consumer:              consumer,
		walkAlreadyDiscovered: walkAlreadyDiscovered,
		abortSignal:           abortSignal,
	}
}

func (t *ChildrenTraverser) cleanup(forceRelease bool) {

	// release all tx metadata at the end
	for _, cachedMsgMeta := range t.cachedMsgMetas {
		cachedMsgMeta.Release(forceRelease) // meta -1
	}

	// Release lock after cleanup so the traverser can be reused
	t.traverserLock.Unlock()
}

func (t *ChildrenTraverser) reset() {

	t.cachedMsgMetas = make(map[string]*tangle.CachedMetadata)
	t.discovered = make(map[string]struct{})
	t.stack = list.New()
}

// Traverse starts to traverse the children (future cone) of the given start message until
// the traversal stops due to no more transactions passing the given condition.
// It is unsorted BFS because the children are not ordered in the database.
func (t *ChildrenTraverser) Traverse(startTxHash hornet.Hash) error {

	// make sure only one traversal is running
	t.traverserLock.Lock()

	// Prepare for a new traversal
	t.reset()

	defer t.cleanup(true)

	t.stack.PushFront(startTxHash)
	if !t.walkAlreadyDiscovered {
		t.discovered[string(startTxHash)] = struct{}{}
	}

	for t.stack.Len() > 0 {
		if err := t.processStackChildren(); err != nil {
			return err
		}
	}

	return nil
}

// processStackChildren checks if the current element in the stack must be processed and traversed.
// current element gets consumed first, afterwards it's children get traversed in random order.
func (t *ChildrenTraverser) processStackChildren() error {

	select {
	case <-t.abortSignal:
		return tangle.ErrOperationAborted
	default:
	}

	// load candidate tx
	ele := t.stack.Front()
	currentTxHash := ele.Value.(hornet.Hash)

	// remove the message from the stack
	t.stack.Remove(ele)

	cachedMsgMeta, exists := t.cachedMsgMetas[string(currentTxHash)]
	if !exists {
		cachedMsgMeta = tangle.GetCachedMessageMetadataOrNil(currentTxHash) // meta +1
		if cachedMsgMeta == nil {
			// there was an error, stop processing the stack
			return errors.Wrapf(tangle.ErrMessageNotFound, "hash: %s", currentTxHash.Hex())
		}
		t.cachedMsgMetas[string(currentTxHash)] = cachedMsgMeta
	}

	// check condition to decide if tx should be consumed and traversed
	traverse, err := t.condition(cachedMsgMeta.Retain()) // meta + 1
	if err != nil {
		// there was an error, stop processing the stack
		return err
	}

	if !traverse {
		// message will not get consumed and children are not traversed
		return nil
	}

	if t.consumer != nil {
		// consume the message
		if err := t.consumer(cachedMsgMeta.Retain()); err != nil { // meta +1
			// there was an error, stop processing the stack
			return err
		}
	}

	for _, childHash := range tangle.GetChildrenMessageIDs(currentTxHash) {
		if !t.walkAlreadyDiscovered {
			if _, childDiscovered := t.discovered[string(childHash)]; childDiscovered {
				// child was already discovered
				continue
			}

			t.discovered[string(childHash)] = struct{}{}
		}

		// traverse the child
		t.stack.PushBack(childHash)
	}

	return nil
}
