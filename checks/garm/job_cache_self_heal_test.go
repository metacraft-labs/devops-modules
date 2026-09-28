// Gate `t_garm_job_cache_self_heal` (checks/garm-job-cache-self-heal.nix).
//
// This file is copied into GARM's own runner/pool package and runs GARM's own
// basePoolManager.consumeQueuedJobs() against GARM's own sqlDatabase on a real
// SQLite file.
//
// Mocks, and why each one is needed:
//   - The provider and the GitHub client are testify mocks (the same ones
//     GARM's own pool_test.go uses). A hermetic build sandbox has neither a
//     hypervisor nor github.com. The code under test only needs AddRunner()
//     to reach the store, which it does before any provider call.
//   - The database watcher is GARM's MockWatcher, so no watcher notification
//     ever reaches the manager's in-memory job cache. That is the point: the
//     defect is a cache that DISAGREES with the store because a notification
//     was lost or reordered, and the tests set up that disagreement directly.
//
//go:build testing

package pool

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/suite"

	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/database"
	dbCommon "github.com/cloudbase/garm/database/common"
	garmTesting "github.com/cloudbase/garm/internal/testing"
	"github.com/cloudbase/garm/locking"
	"github.com/cloudbase/garm/params"
	"github.com/cloudbase/garm/runner/common"
	runnerCommonMocks "github.com/cloudbase/garm/runner/common/mocks"
)

type JobCacheSelfHealSuite struct {
	suite.Suite

	store    dbCommon.Store
	adminCtx context.Context
	entity   params.ForgeEntity
	pool     params.Pool
	mgr      *basePoolManager
}

var jobCacheLabels = []string{"self-hosted", "windows", "x64"}

func (s *JobCacheSelfHealSuite) SetupTest() {
	db, err := database.NewDatabase(context.Background(), garmTesting.GetTestSqliteDBConfig(s.T()))
	s.Require().NoError(err)
	s.store = db
	s.adminCtx = garmTesting.ImpersonateAdminContext(context.Background(), db, s.T())

	endpoint := garmTesting.CreateDefaultGithubEndpoint(s.adminCtx, db, s.T())
	creds := garmTesting.CreateTestGithubCredentials(s.adminCtx, "self-heal-creds", db, s.T(), endpoint)
	repo, err := db.CreateRepository(s.adminCtx, "test-owner", "test-repo", creds,
		"test-webhook-secret", params.PoolBalancerTypeRoundRobin, false)
	s.Require().NoError(err)
	s.entity, err = repo.GetEntity()
	s.Require().NoError(err)

	s.pool, err = db.CreateEntityPool(s.adminCtx, s.entity, params.CreatePoolParams{
		ProviderName:   "test-provider",
		MaxRunners:     2,
		MinIdleRunners: 0,
		Image:          "test-image",
		Flavor:         "test-flavor",
		OSType:         "windows",
		OSArch:         "amd64",
		Tags:           jobCacheLabels,
		Enabled:        true,
	})
	s.Require().NoError(err)
	cache.SetEntity(s.entity)
	cache.SetEntityPool(s.entity.ID, s.pool)

	controllerInfo, err := db.InitController()
	s.Require().NoError(err)
	controllerInfo.MinimumJobAgeBackoff = 0

	backoff, err := locking.NewInstanceDeleteBackoff(context.Background())
	s.Require().NoError(err)

	provider := runnerCommonMocks.NewProvider(s.T())
	provider.On("DisableJITConfig").Return(true).Maybe()
	ghcli := runnerCommonMocks.NewGithubClient(s.T())
	ghcli.On("GetEntityJITConfig", mock.Anything, mock.Anything, mock.Anything, mock.Anything).
		Return(map[string]string{}, nil, nil).Maybe()

	s.mgr = &basePoolManager{
		ctx:              s.adminCtx,
		consumerID:       "self-heal-consumer",
		entity:           s.entity,
		store:            db,
		controllerInfo:   controllerInfo,
		providers:        map[string]common.Provider{"test-provider": provider},
		jobs:             make(map[int64]params.Job),
		checkedJobs:      make(map[int64]time.Time),
		quit:             make(chan struct{}),
		consumer:         &garmTesting.MockConsumer{},
		wg:               &sync.WaitGroup{},
		backoff:          backoff,
		ghcli:            ghcli,
		managerIsRunning: true,
	}
}

func (s *JobCacheSelfHealSuite) queueJob(workflowJobID int64) params.Job {
	_, err := s.store.CreateOrUpdateJob(s.adminCtx, params.Job{
		WorkflowJobID:   workflowJobID,
		Action:          "queued",
		Status:          "queued",
		Labels:          jobCacheLabels,
		RepositoryName:  "test-repo",
		RepositoryOwner: "test-owner",
		RepoID:          garmTesting.Ptr(uuid.MustParse(s.entity.ID)),
	})
	s.Require().NoError(err)
	return s.storedJob(workflowJobID)
}

func (s *JobCacheSelfHealSuite) storedJob(workflowJobID int64) params.Job {
	queued, err := s.store.ListJobsByStatus(s.adminCtx, params.JobStatusQueued)
	s.Require().NoError(err)
	for _, j := range queued {
		if j.WorkflowJobID == workflowJobID {
			return j
		}
	}
	s.FailNow("job is not queued in the store", "workflow_job_id %d", workflowJobID)
	return params.Job{}
}

// cacheJobs sets the manager's in-memory cache, keyed by the job record ID
// exactly as runner/pool/watcher.go keys it.
func (s *JobCacheSelfHealSuite) cacheJobs(jobs ...params.Job) {
	s.mgr.mux.Lock()
	defer s.mgr.mux.Unlock()
	for _, j := range jobs {
		s.mgr.jobs[j.ID] = j
	}
}

func (s *JobCacheSelfHealSuite) runnerCount() int {
	instances, err := s.store.ListPoolInstances(s.adminCtx, s.pool.ID, false)
	s.Require().NoError(err)
	return len(instances)
}

// The incident (central GARM, 2026-09-28): the store has the job queued and
// UNLOCKED, the cache still says "locked by us" (the unlock notification was
// lost or overtaken by the lock's), and it has been that way for more than 10
// minutes. A slot is free. The job must be served.
func (s *JobCacheSelfHealSuite) TestStaleCachedLockIsHealed() {
	stored := s.queueJob(9001)
	s.Require().Equal(uuid.Nil, stored.LockedBy)

	cached := stored
	cached.LockedBy = uuid.MustParse(s.mgr.ID())
	cached.UpdatedAt = time.Now().UTC().Add(-11 * time.Minute)
	s.cacheJobs(cached)

	s.Require().NoError(s.mgr.consumeQueuedJobs())
	s.Equal(1, s.runnerCount(), "the stranded job must get a runner once its cached lock is past the 10 minute retry")
	s.Equal(uuid.MustParse(s.mgr.ID()), s.storedJob(9001).LockedBy)
}

// A cached job the store no longer has (its delete notification was lost) is
// dropped from the cache instead of being retried on every pass.
func (s *JobCacheSelfHealSuite) TestGhostJobIsDropped() {
	real := s.queueJob(9102)
	ghost := real
	ghost.ID = real.ID + 1000
	ghost.WorkflowJobID = 9101
	ghost.UpdatedAt = time.Now().UTC().Add(-time.Minute)
	s.cacheJobs(ghost, real)

	s.Require().NoError(s.mgr.consumeQueuedJobs())

	s.mgr.mux.Lock()
	_, stillCached := s.mgr.jobs[ghost.ID]
	s.mgr.mux.Unlock()
	s.False(stillCached, "a job missing from the store must leave the cache")
	s.Equal(1, s.runnerCount(), "the real job must still be served")
}

// CONTROL (must pass with and without the patch): an ordinary queued job
// whose cache agrees with the store is served.
func (s *JobCacheSelfHealSuite) TestFreshQueuedJobIsServed() {
	stored := s.queueJob(9201)
	s.cacheJobs(stored)

	s.Require().NoError(s.mgr.consumeQueuedJobs())
	s.Equal(1, s.runnerCount())
}

// CONTROL (must pass with and without the patch): a job this manager really
// holds a lock on, inside the 10 minute window, is NOT served again. The
// patch must not turn every pass into a duplicate runner.
func (s *JobCacheSelfHealSuite) TestGenuineRecentLockIsRespected() {
	s.queueJob(9301)
	s.Require().NoError(s.store.LockJob(s.adminCtx, 9301, s.mgr.ID()))
	locked := s.storedJob(9301)
	s.Require().Equal(uuid.MustParse(s.mgr.ID()), locked.LockedBy)
	locked.UpdatedAt = time.Now().UTC().Add(-2 * time.Minute)
	s.cacheJobs(locked)

	s.Require().NoError(s.mgr.consumeQueuedJobs())
	s.Equal(0, s.runnerCount(), "a job locked by us less than 10 minutes ago must not get a second runner")
	s.Equal(uuid.MustParse(s.mgr.ID()), s.storedJob(9301).LockedBy)
}

func TestJobCacheSelfHealSuite(t *testing.T) {
	suite.Run(t, new(JobCacheSelfHealSuite))
}
