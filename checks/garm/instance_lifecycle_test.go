// Copyright 2026 Cloudbase Solutions SRL
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain
//    a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
//    License for the specific language governing permissions and limitations
//    under the License.

//go:build testing

// Gate t_garm_instance_lifecycle — GARM must never FORGET an instance its
// provider may still hold, and must not turn one failing provider into a
// delete storm against every other.
//
// WHAT IS UNDER TEST
//
//	GARM's own basePoolManager.cleanupOrphanedGithubRunners() and
//	retryFailedInstancesForOnePool(), called directly. The store is the REAL
//	sqlDatabase on a REAL SQLite file. The mocked boundaries are the provider
//	(runner/common/mocks.Provider) and the forge (mocks.GithubClient): the
//	properties are about what GARM does with a provider's ANSWERS, and the
//	answers that matter — an empty list, a failed delete, a delete cancelled
//	mid-flight — are exactly the ones a real provider cannot be made to give
//	on demand. Nothing about the pool manager is re-implemented here.
//
// THE PRODUCTION DEFECTS (central GARM, high-mem-server, 2026-09-22/23)
//
//	1. cleanupOrphanedGithubRunners: a runner offline in GitHub for >5 min
//	   whose name is absent from the provider's ListInstances had its DB row
//	   DELETED and the provider's DeleteInstance was never called. The remote
//	   vmharness provider answered every ListInstances with an empty list, so
//	   every Windows runner (still booting at 5 min) was forgotten while its VM
//	   ran on: ~210 leaked libvirt domains. TestDroppedInstanceIsDeletedViaProvider.
//
//	2. retryFailedInstancesForOnePool ran a pool's cleanup deletes in one
//	   errgroup.WithContext: the first failure CANCELLED every sibling delete
//	   (the provider binary is SIGKILLed) and they were all retried every 5s.
//	   ~88k "failed to delete instance from provider" in 24h, ~31k of them
//	   `signal: killed` and ~23k `context canceled`.
//	   TestFailedDeleteDoesNotCancelSiblings, TestFailedCleanupDeleteBacksOff.
//
//	3. A create that fails fast (full storage pool) was re-queued every 5s,
//	   burning all attempts in seconds (~143 creates/hour/pool observed).
//	   TestCreateRetryIsBackedOff.
//
// WHY IT DISCRIMINATES
//
//	checks/t_garm_instance_lifecycle.sh runs this file against the patched
//	tree (all pass) and against the same tree minus the patch (the four
//	defect tests fail). The file references no symbol the patch introduces, so
//	the unpatched tree compiles and fails for the RIGHT reason.
package pool

import (
	"context"
	"database/sql"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/suite"

	commonParams "github.com/cloudbase/garm-provider-common/params"
	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/config"
	"github.com/cloudbase/garm/database"
	dbCommon "github.com/cloudbase/garm/database/common"
	garmTesting "github.com/cloudbase/garm/internal/testing"
	"github.com/cloudbase/garm/locking"
	"github.com/cloudbase/garm/params"
	"github.com/cloudbase/garm/runner/common"
	runnerCommonMocks "github.com/cloudbase/garm/runner/common/mocks"
)

func init() {
	lock, err := locking.NewLocalLocker(context.Background(), nil)
	if err != nil {
		panic(err)
	}
	_ = locking.RegisterLocker(lock)
}

type InstanceLifecycleSuite struct {
	suite.Suite

	dbCfg    config.Database
	store    dbCommon.Store
	adminCtx context.Context
	pool     params.Pool
	mgr      *basePoolManager
	provider *runnerCommonMocks.Provider
	ghcli    *runnerCommonMocks.GithubClient
}

func (s *InstanceLifecycleSuite) SetupTest() {
	s.dbCfg = garmTesting.GetTestSqliteDBConfig(s.T())
	db, err := database.NewDatabase(context.Background(), s.dbCfg)
	s.Require().NoError(err)
	s.store = db
	s.adminCtx = garmTesting.ImpersonateAdminContext(context.Background(), db, s.T())

	endpoint := garmTesting.CreateDefaultGithubEndpoint(s.adminCtx, db, s.T())
	creds := garmTesting.CreateTestGithubCredentials(s.adminCtx, "lifecycle-creds", db, s.T(), endpoint)
	org, err := db.CreateOrganization(s.adminCtx, "metacraft-labs", creds, "secret",
		params.PoolBalancerTypeRoundRobin, false)
	s.Require().NoError(err)
	entity, err := org.GetEntity()
	s.Require().NoError(err)

	s.pool, err = db.CreateEntityPool(s.adminCtx, entity, params.CreatePoolParams{
		ProviderName: "hms-libvirt",
		MaxRunners:   10,
		Image:        "golden",
		Flavor:       "default",
		OSType:       "windows",
		OSArch:       "amd64",
		Tags:         []string{"self-hosted", "windows", "x64"},
		Enabled:      true,
	})
	s.Require().NoError(err)
	cache.SetEntity(entity)
	cache.SetEntityPool(entity.ID, s.pool)

	controllerInfo, err := db.InitController()
	s.Require().NoError(err)
	backoff, err := locking.NewInstanceDeleteBackoff(context.Background())
	s.Require().NoError(err)

	s.provider = runnerCommonMocks.NewProvider(s.T())
	s.ghcli = runnerCommonMocks.NewGithubClient(s.T())
	s.mgr = &basePoolManager{
		ctx:              s.adminCtx,
		consumerID:       "lifecycle-test-consumer",
		entity:           entity,
		store:            db,
		controllerInfo:   controllerInfo,
		providers:        map[string]common.Provider{"hms-libvirt": s.provider},
		jobs:             make(map[int64]params.Job),
		checkedJobs:      make(map[int64]time.Time),
		quit:             make(chan struct{}),
		consumer:         &garmTesting.MockConsumer{},
		wg:               &sync.WaitGroup{},
		backoff:          backoff,
		ghcli:            s.ghcli,
		managerIsRunning: true,
	}
}

// newInstance creates an instance and returns its STORED CreateAttempt (the
// store does not take the create-time value verbatim, so assertions are made
// relative to what was actually persisted).
func (s *InstanceLifecycleSuite) newInstance(name string, status commonParams.InstanceStatus, attempt int) int {
	inst, err := s.store.CreateInstance(s.adminCtx, s.pool.ID, params.CreateInstanceParams{
		Name:          name,
		OSType:        "windows",
		OSArch:        "amd64",
		Status:        status,
		RunnerStatus:  params.RunnerPending,
		CreateAttempt: attempt,
	})
	s.Require().NoError(err)
	return inst.CreateAttempt
}

// age backdates an instance's updated_at, which is what every age check under
// test reads. The ONLY direct SQL in the gate.
func (s *InstanceLifecycleSuite) age(name string, by time.Duration) {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()
	res, err := conn.Exec("UPDATE instances SET updated_at = ? WHERE name = ?", time.Now().Add(-by), name)
	s.Require().NoError(err)
	n, err := res.RowsAffected()
	s.Require().NoError(err)
	s.Require().EqualValues(1, n)
}

func (s *InstanceLifecycleSuite) offlineRunner(id int64, name string) forgeRunner {
	return forgeRunner{
		ID: id, Name: name, Status: "offline",
		Labels: []RunnerLabels{{Name: controllerLabelPrefix + ":" + s.mgr.controllerInfo.ControllerID.String()}},
	}
}

// ---------------------------------------------------------------------------
// 1. "Absent from the provider" must route through the provider's delete.
// ---------------------------------------------------------------------------

func (s *InstanceLifecycleSuite) TestDroppedInstanceIsDeletedViaProvider() {
	// garm-qglasrc9bvey: created 08:24:15, offline in GitHub (still booting
	// Windows), absent from ListInstances at 08:30:16.
	s.newInstance("garm-qglasrc9bvey", commonParams.InstanceRunning, 1)
	s.age("garm-qglasrc9bvey", 6*time.Minute)

	s.provider.On("ListInstances", mock.Anything, s.pool.ID, mock.Anything).
		Return([]commonParams.ProviderInstance{}, nil).Once()
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(4242)).Return(nil).Once()

	s.Require().NoError(s.mgr.cleanupOrphanedGithubRunners(
		[]forgeRunner{s.offlineRunner(4242, "garm-qglasrc9bvey")}))

	inst, err := s.store.GetInstance(s.adminCtx, "garm-qglasrc9bvey")
	s.Require().NoError(err,
		"the DB record was deleted outright: DeleteInstance will never be called and the VM leaks")
	s.Require().Equal(commonParams.InstancePendingDelete, inst.Status,
		"the instance must be handed to the deletion path, which calls the provider's DeleteInstance")
}

// ---------------------------------------------------------------------------
// 2. One failing delete must not cancel its siblings, nor abort the pass.
// ---------------------------------------------------------------------------

func (s *InstanceLifecycleSuite) TestFailedDeleteDoesNotCancelSiblings() {
	s.newInstance("garm-unreachable", commonParams.InstanceError, 1)
	healthyAttempt := s.newInstance("garm-healthy", commonParams.InstanceError, 1)
	s.age("garm-unreachable", 10*time.Minute)
	s.age("garm-healthy", 10*time.Minute)

	s.provider.On("DeleteInstance", mock.Anything, "garm-unreachable", mock.Anything).
		Return(errors.New("dial tcp 100.83.174.120:8873: connect: connection refused")).Once()

	var cancelled atomic.Bool
	s.provider.On("DeleteInstance", mock.Anything, "garm-healthy", mock.Anything).
		Run(func(args mock.Arguments) {
			ctx := args.Get(0).(context.Context)
			select {
			case <-ctx.Done():
				cancelled.Store(true) // the provider binary would be SIGKILLed here
			case <-time.After(1500 * time.Millisecond):
			}
		}).Return(nil).Once()

	err := s.mgr.retryFailedInstancesForOnePool(s.adminCtx, s.pool)
	s.Require().False(cancelled.Load(),
		"a sibling's failed delete cancelled this delete mid-flight")
	s.Require().NoError(err, "one instance's failure must not fail the pass")

	healthy, err := s.store.GetInstance(s.adminCtx, "garm-healthy")
	s.Require().NoError(err)
	s.Require().Equal(commonParams.InstancePendingCreate, healthy.Status)
	s.Require().Equal(healthyAttempt+1, healthy.CreateAttempt)

	stuck, err := s.store.GetInstance(s.adminCtx, "garm-unreachable")
	s.Require().NoError(err)
	s.Require().Equal(commonParams.InstanceError, stuck.Status,
		"an instance whose cleanup delete failed must NOT be re-created")
}

func (s *InstanceLifecycleSuite) TestFailedCleanupDeleteBacksOff() {
	s.newInstance("garm-unreachable", commonParams.InstanceError, 1)
	s.age("garm-unreachable", 10*time.Minute)
	s.provider.On("DeleteInstance", mock.Anything, "garm-unreachable", mock.Anything).
		Return(errors.New("connect: connection refused"))

	for i := 0; i < 3; i++ { // three consecutive 5s ticks
		_ = s.mgr.retryFailedInstancesForOnePool(s.adminCtx, s.pool)
	}
	s.provider.AssertNumberOfCalls(s.T(), "DeleteInstance", 1)
}

// ---------------------------------------------------------------------------
// 3. Create retries are spaced out.
// ---------------------------------------------------------------------------

func (s *InstanceLifecycleSuite) TestCreateRetryIsBackedOff() {
	// Just failed (Failed to chmod mount directory — the pool is full).
	freshAttempt := s.newInstance("garm-just-failed", commonParams.InstanceError, 1)
	// Failed long enough ago that its backoff has elapsed.
	s.newInstance("garm-failed-earlier", commonParams.InstanceError, 1)
	s.age("garm-failed-earlier", 10*time.Minute)

	s.provider.On("DeleteInstance", mock.Anything, "garm-failed-earlier", mock.Anything).Return(nil).Once()

	s.Require().NoError(s.mgr.retryFailedInstancesForOnePool(s.adminCtx, s.pool))

	fresh, err := s.store.GetInstance(s.adminCtx, "garm-just-failed")
	s.Require().NoError(err)
	s.Require().Equal(commonParams.InstanceError, fresh.Status,
		"a create that failed moments ago was re-queued immediately")
	s.Require().Equal(freshAttempt, fresh.CreateAttempt)

	due, err := s.store.GetInstance(s.adminCtx, "garm-failed-earlier")
	s.Require().NoError(err)
	s.Require().Equal(commonParams.InstancePendingCreate, due.Status,
		"an instance whose backoff has elapsed must still be retried")
}

func TestInstanceLifecycleSuite(t *testing.T) {
	suite.Run(t, new(InstanceLifecycleSuite))
}
