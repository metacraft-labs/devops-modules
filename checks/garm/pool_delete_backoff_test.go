// Copyright 2026 Cloudbase Solutions SRL
//
//	Licensed under the Apache License, Version 2.0 (the "License"); you may
//	not use this file except in compliance with the License. You may obtain
//	a copy of the License at
//
//	     http://www.apache.org/licenses/LICENSE-2.0
//
//	Unless required by applicable law or agreed to in writing, software
//	distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//	WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
//	License for the specific language governing permissions and limitations
//	under the License.

//go:build testing
// +build testing

package pool

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	commonParams "github.com/cloudbase/garm-provider-common/params"
	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/database"
	garmTesting "github.com/cloudbase/garm/internal/testing"
	"github.com/cloudbase/garm/locking"
	"github.com/cloudbase/garm/params"
	"github.com/cloudbase/garm/runner/common"
	runnerCommonMocks "github.com/cloudbase/garm/runner/common/mocks"
)

// The tests in this file are run twice by the devops-modules gate
// t_garm_pool_delete_backoff: against the shipped tree, where they must pass,
// and against the same tree without fix-pool-delete-backoff.patch, where each
// must fail. They only use APIs both trees have, so the control fails on its
// assertions, not on compilation.

var registerLockerOnce sync.Once

func ensureLocker(t *testing.T) {
	registerLockerOnce.Do(func() {
		l, err := locking.NewLocalLocker(context.Background(), nil)
		require.NoError(t, err)
		// Another test of the package may have registered one already.
		_ = locking.RegisterLocker(l)
	})
}

// logCapture collects slog records from the default logger.
type logCapture struct {
	mux sync.Mutex
	buf bytes.Buffer
}

func (c *logCapture) Write(p []byte) (int, error) {
	c.mux.Lock()
	defer c.mux.Unlock()
	return c.buf.Write(p)
}

func (c *logCapture) lines(substr string) []string {
	c.mux.Lock()
	defer c.mux.Unlock()
	var out []string
	for _, l := range strings.Split(c.buf.String(), "\n") {
		if strings.Contains(l, substr) {
			out = append(out, l)
		}
	}
	return out
}

func captureLogs(t *testing.T) *logCapture {
	c := &logCapture{}
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(c, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(prev) })
	return c
}

type backoffFixture struct {
	mgr      *basePoolManager
	provider *runnerCommonMocks.Provider
	ghcli    *runnerCommonMocks.GithubClient
	pool     params.Pool
	ctx      context.Context
}

func newBackoffFixture(t *testing.T) *backoffFixture {
	ensureLocker(t)
	db, err := database.NewDatabase(context.Background(), garmTesting.GetTestSqliteDBConfig(t))
	require.NoError(t, err)
	adminCtx := garmTesting.ImpersonateAdminContext(context.Background(), db, t)
	endpoint := garmTesting.CreateDefaultGithubEndpoint(adminCtx, db, t)
	creds := garmTesting.CreateTestGithubCredentials(adminCtx, "backoff-creds", db, t, endpoint)
	repo, err := db.CreateRepository(adminCtx, "backoff-owner", "backoff-repo", creds,
		"test-webhook-secret", params.PoolBalancerTypeRoundRobin, false)
	require.NoError(t, err)
	entity, err := repo.GetEntity()
	require.NoError(t, err)
	pool, err := db.CreateEntityPool(adminCtx, entity, params.CreatePoolParams{
		ProviderName: "test-provider",
		MaxRunners:   10,
		Image:        "test-image",
		Flavor:       "test-flavor",
		OSType:       "linux",
		OSArch:       "amd64",
		Tags:         []string{"self-hosted", "linux", "x64"},
		Enabled:      true,
	})
	require.NoError(t, err)
	cache.SetEntity(entity)
	cache.SetEntityPool(entity.ID, pool)
	backoff, err := locking.NewInstanceDeleteBackoff(context.Background())
	require.NoError(t, err)

	provider := runnerCommonMocks.NewProvider(t)
	ghcli := runnerCommonMocks.NewGithubClient(t)
	return &backoffFixture{
		mgr: &basePoolManager{
			ctx:              adminCtx,
			consumerID:       "backoff-test",
			entity:           entity,
			store:            db,
			providers:        map[string]common.Provider{"test-provider": provider},
			quit:             make(chan struct{}),
			wg:               &sync.WaitGroup{},
			backoff:          backoff,
			ghcli:            ghcli,
			managerIsRunning: true,
		},
		provider: provider,
		ghcli:    ghcli,
		pool:     pool,
		ctx:      adminCtx,
	}
}

func (f *backoffFixture) createInstance(t *testing.T, name string, status commonParams.InstanceStatus, runnerStatus params.RunnerStatus, agentID int64) params.Instance {
	inst, err := f.mgr.store.CreateInstance(f.ctx, f.pool.ID, params.CreateInstanceParams{
		Name:         name,
		OSType:       commonParams.Linux,
		OSArch:       commonParams.Amd64,
		Status:       status,
		RunnerStatus: runnerStatus,
		AgentID:      agentID,
	})
	require.NoError(t, err)
	return inst
}

// lockHeld reports whether someone holds name's instance lock right now. It
// takes and releases the lock when it is free.
func lockHeld(name string) bool {
	if locking.TryLock(name, "probe") {
		locking.Unlock(name, false)
		return false
	}
	return true
}

func waitFor(t *testing.T, what string, cond func() bool) {
	deadline := time.Now().Add(30 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// failingDelete makes the provider's DeleteInstance fail the way a pinned
// incus dataset did (2026-11-16..18) and counts the calls.
func (f *backoffFixture) failingDelete(name string) func() int {
	var mux sync.Mutex
	calls := 0
	f.provider.On("DeleteInstance", mock.Anything, name, mock.Anything).
		Run(func(mock.Arguments) { mux.Lock(); calls++; mux.Unlock() }).
		Return(errors.New("cannot destroy 'pool/containers/" + name + "': dataset is busy"))
	return func() int { mux.Lock(); defer mux.Unlock(); return calls }
}

// waitForAttempt waits until the delete goroutine started for name has
// called the provider `want` times and released the instance.
func waitForAttempt(t *testing.T, name string, calls func() int, want int) {
	waitFor(t, "the provider delete", func() bool { return calls() >= want })
	waitFor(t, "the delete to release the instance", func() bool { return !lockHeld(name) })
	require.Equal(t, want, calls())
}

// TestPoolDeletePendingInBackoffLogsNoAttempt: the delete loop runs every
// 5s. A pass that skips an instance because its backoff is in effect must not
// log "removing instance from pool" at info level: on 2026-11-16 that line
// was logged ~311 times per instance in 30 minutes and read as a delete every
// 6s, while the real attempts were ~24 minutes apart.
func TestPoolDeletePendingInBackoffLogsNoAttempt(t *testing.T) {
	f := newBackoffFixture(t)
	logs := captureLogs(t)
	const name = "garm-quiet-backoff"
	f.createInstance(t, name, commonParams.InstancePendingDelete, params.RunnerTerminated, 0)
	calls := f.failingDelete(name)

	f.mgr.backoff.RecordFailure(name)
	for range 3 {
		require.NoError(t, f.mgr.deletePendingInstances())
	}
	require.False(t, lockHeld(name), "a delete was started while the instance was in backoff")
	require.Empty(t, logs.lines(`msg="removing instance from pool"`),
		"passes that skipped the instance (backoff in effect) logged \"removing instance from pool\" at info level")

	// Control: with the backoff cleared the same pass starts a delete and
	// logs it once, so the absence above was observed on a working capture.
	f.mgr.backoff.Delete(name)
	require.NoError(t, f.mgr.deletePendingInstances())
	waitForAttempt(t, name, calls, 1)
	require.Len(t, logs.lines(`msg="removing instance from pool"`), 1,
		"control: the attempted delete was not logged")
}

// TestPoolDeleteFailureWarnsAndDoubles: each failed delete logs a warning
// that carries the consecutive failure count and the wait, and the wait
// doubles (5s, 10s, ...; the 1.5x progression gave 7.5s for the second).
func TestPoolDeleteFailureWarnsAndDoubles(t *testing.T) {
	f := newBackoffFixture(t)
	logs := captureLogs(t)
	const name = "garm-busy-dataset"
	f.createInstance(t, name, commonParams.InstancePendingDelete, params.RunnerTerminated, 0)
	calls := f.failingDelete(name)

	require.NoError(t, f.mgr.deletePendingInstances())
	waitForAttempt(t, name, calls, 1)

	var backoffWarns []string
	for _, w := range logs.lines("level=WARN") {
		if strings.Contains(w, "runner_name="+name) && strings.Contains(w, "backing off") {
			backoffWarns = append(backoffWarns, w)
		}
	}
	require.Len(t, backoffWarns, 1, "a failed delete must log exactly one backoff warning; WARN lines: %q", logs.lines("level=WARN"))
	require.Contains(t, backoffWarns[0], "consecutive_failures=1")
	require.Contains(t, backoffWarns[0], "retry_in=5s")

	// Control: the failure did put the instance in backoff, and the next
	// pass leaves the provider alone.
	ok, _ := f.mgr.backoff.ShouldProcess(name)
	require.False(t, ok, "control: the failed delete did not put the instance in backoff")
	require.NoError(t, f.mgr.deletePendingInstances())
	require.False(t, lockHeld(name))
	require.Equal(t, 1, calls())

	before := time.Now()
	f.mgr.backoff.RecordFailure(name)
	after := time.Now()
	_, deadline := f.mgr.backoff.ShouldProcess(name)
	require.False(t, deadline.Before(before.Add(10*time.Second)),
		"the second backoff step ends %s after the failure: it did not double from 5s to 10s", deadline.Sub(before))
	require.False(t, deadline.After(after.Add(10*time.Second)),
		"the second backoff step ends %s after the failure, past 10s", deadline.Sub(after))
}

// TestPoolSweepReleasesEachInstanceLock: the orphan sweep must release an
// instance's lock when it is done with that instance. With a defer in the
// loop body every lock was held until the whole sweep returned, and on
// 2026-11-18 deletePendingInstances logged "failed to acquire lock" for
// minutes at a time, every 5 minutes, for instances it should have deleted.
func TestPoolSweepReleasesEachInstanceLock(t *testing.T) {
	f := newBackoffFixture(t)
	names := []string{"garm-sweep-a", "garm-sweep-b", "garm-sweep-c"}
	agentToName := map[int64]string{}
	for i, n := range names {
		f.createInstance(t, n, commonParams.InstanceRunning, params.RunnerActive, int64(100+i))
		agentToName[int64(100+i)] = n
	}

	// Each forge call is made while the sweep works on one instance. At that
	// moment no OTHER instance's lock may be held: the earlier ones are done,
	// the later ones not yet started.
	var mux sync.Mutex
	var calls int
	heldDuringCall := map[string][]string{}
	selfHeld := map[string]bool{}
	f.ghcli.On("RemoveEntityRunner", mock.Anything, mock.Anything).
		Run(func(args mock.Arguments) {
			current := agentToName[args.Get(1).(int64)]
			mux.Lock()
			defer mux.Unlock()
			calls++
			// Control: the instance being worked on IS locked, so the probe
			// can see a held lock.
			selfHeld[current] = lockHeld(current)
			for _, other := range names {
				if other != current && lockHeld(other) {
					heldDuringCall[current] = append(heldDuringCall[current], other)
				}
			}
		}).Return(nil)

	// No forge runner listed: every instance is an active runner missing
	// from the forge, so the sweep asks the forge about each one.
	require.NoError(t, f.mgr.cleanupOrphanedProviderRunners(nil))

	mux.Lock()
	defer mux.Unlock()
	require.Equal(t, len(names), calls, "the sweep did not reach every instance")
	for _, n := range names {
		require.True(t, selfHeld[n], "control: the probe did not see %s's own lock as held", n)
	}
	require.Empty(t, heldDuringCall,
		"the sweep kept earlier instances locked while it worked on later ones (instance -> locks still held): %v", heldDuringCall)
	for _, n := range names {
		require.False(t, lockHeld(n), "%s is still locked after the sweep", n)
	}
}
