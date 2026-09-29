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

// Gate t_garm_busy_runner_not_reaped — GARM must never retire a runner the
// forge reports busy, and one runner the forge will not release must not stop
// the rest of the cleanup pass.
//
// WHAT IS UNDER TEST
//
//	GARM's own basePoolManager.runnerCleanup() (the body of the "runner
//	cleanup" loop: list the forge's runners, reapTimedOutRunners,
//	cleanupOrphanedRunners) and cleanupOrphanedProviderRunners(), called
//	directly. The runner list is produced by GARM's own
//	listRunnersWithPagination() from the forge's answer, so the busy flag
//	travels the same path it does in production. The store is the REAL
//	sqlDatabase on a REAL SQLite file.
//
// MOCKS, AND WHY EACH ONE IS NEEDED
//
//   - The forge client (runner/common/mocks.GithubClient). The properties are
//     about what GARM does with the forge's ANSWERS — "offline but busy",
//     "422 still running a job", "not found" — and a sandbox has no
//     github.com, nor any way to make the real one give those answers on
//     demand. The 422 the mock returns is runnerErrors.ErrBadRequest, which is
//     exactly what util/github maps GitHub's 422 to.
//   - The provider (runner/common/mocks.Provider) is registered but must
//     never be called: nothing here should reach a hypervisor.
//
// THE PRODUCTION OBSERVATION (central GARM, high-mem-server, 2026-09-27..29)
//
//	63 runners were "reaped" in 2.5 days. 17 of them were mid-job: GitHub
//	reported them offline (the listener session lapsed: the host was starved
//	or partitioned; two of the gpu-server-001 "lost communication" failures
//	fall inside windows where that host was unreachable) but busy, and
//	refused the removal with 422. GARM did not destroy any of
//	them: for all 376 failed/cancelled agent-harbor jobs on GARM runners in
//	the window, the instance was removed AFTER GitHub had ended the job. The
//	jobs died of "lost communication"; the reap was a symptom, not the cause.
//
//	The defects that remain are GARM's, and are what this gate pins:
//	  - upstream GARM does not read the busy flag at all; the forge's 422 is
//	    the only thing standing between a running job and DeleteRunner;
//	  - each refusal aborted reapTimedOutRunners AND skipped the orphan sweep
//	    for the entity, every pass, until the job ended;
//	  - cleanupOrphanedProviderRunners force-marks pending_delete any instance
//	    missing from one listing of the forge's runners, with no age check and
//	    without asking the forge, so a listing that drops a busy runner
//	    destroys its instance under the job.
//
// WHY IT DISCRIMINATES
//
//	checks/t_garm_busy_runner_not_reaped.sh runs this file against the
//	patched tree (all pass) and against the same tree minus
//	fix-busy-runner-reap.patch (the three defect tests fail, the two controls
//	pass). The file references no symbol the patch introduces: the busy flag
//	enters through go-github's Runner.Busy, so the unpatched tree compiles and
//	fails for the RIGHT reason.
package pool

import (
	"context"
	"database/sql"
	"sync"
	"testing"
	"time"

	"github.com/google/go-github/v84/github"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/suite"

	runnerErrors "github.com/cloudbase/garm-provider-common/errors"
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
	// The pool manager takes per-instance locks; register the in-process
	// locker GARM itself uses. RegisterLocker refuses a second registration,
	// so this is safe next to any other test file that does the same.
	lock, err := locking.NewLocalLocker(context.Background(), nil)
	if err != nil {
		panic(err)
	}
	_ = locking.RegisterLocker(lock)
}

type BusyRunnerReapSuite struct {
	suite.Suite

	dbCfg    config.Database
	store    dbCommon.Store
	adminCtx context.Context
	pool     params.Pool
	mgr      *basePoolManager
	provider *runnerCommonMocks.Provider
	ghcli    *runnerCommonMocks.GithubClient
}

func (s *BusyRunnerReapSuite) SetupTest() {
	s.dbCfg = garmTesting.GetTestSqliteDBConfig(s.T())
	db, err := database.NewDatabase(context.Background(), s.dbCfg)
	s.Require().NoError(err)
	s.store = db
	s.adminCtx = garmTesting.ImpersonateAdminContext(context.Background(), db, s.T())

	endpoint := garmTesting.CreateDefaultGithubEndpoint(s.adminCtx, db, s.T())
	creds := garmTesting.CreateTestGithubCredentials(s.adminCtx, "busy-reap-creds", db, s.T(), endpoint)
	org, err := db.CreateOrganization(s.adminCtx, "agent-harbor", creds, "secret",
		params.PoolBalancerTypeRoundRobin, false)
	s.Require().NoError(err)
	entity, err := org.GetEntity()
	s.Require().NoError(err)

	s.pool, err = db.CreateEntityPool(s.adminCtx, entity, params.CreatePoolParams{
		ProviderName:           "gpu001-incus",
		MaxRunners:             4,
		Image:                  "runner",
		Flavor:                 "default",
		OSType:                 "linux",
		OSArch:                 "amd64",
		Tags:                   []string{"self-hosted", "linux", "x64"},
		Enabled:                true,
		RunnerBootstrapTimeout: 20, // the production value
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
		consumerID:       "busy-reap-consumer",
		entity:           entity,
		store:            db,
		controllerInfo:   controllerInfo,
		providers:        map[string]common.Provider{"gpu001-incus": s.provider},
		jobs:             make(map[int64]params.Job),
		checkedJobs:      make(map[int64]time.Time),
		quit:             make(chan struct{}),
		consumer:         &garmTesting.MockConsumer{},
		wg:               &sync.WaitGroup{},
		backoff:          backoff,
		ghcli:            s.ghcli,
		managerIsRunning: true,
		// scaleSetClient stays nil: GetGithubRunners() then lists through
		// listRunnersWithPagination(), i.e. through the mocked forge client.
	}
}

// newInstance creates a running instance whose runner registered with the
// forge as agentID, in the given runner status.
func (s *BusyRunnerReapSuite) newInstance(name string, agentID int64, rs params.RunnerStatus) {
	_, err := s.store.CreateInstance(s.adminCtx, s.pool.ID, params.CreateInstanceParams{
		Name:         name,
		OSType:       "linux",
		OSArch:       "amd64",
		Status:       commonParams.InstanceRunning,
		RunnerStatus: rs,
		AgentID:      agentID,
	})
	s.Require().NoError(err)
}

// age backdates updated_at, which is the clock reapTimedOutRunners reads.
// Nothing refreshes it while a job runs, so a job that started more than the
// bootstrap timeout ago looks exactly like this.
func (s *BusyRunnerReapSuite) age(name string, by time.Duration) {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()
	res, err := conn.Exec("UPDATE instances SET updated_at = ? WHERE name = ?", time.Now().Add(-by), name)
	s.Require().NoError(err)
	n, err := res.RowsAffected()
	s.Require().NoError(err)
	s.Require().EqualValues(1, n)
}

func (s *BusyRunnerReapSuite) status(name string) commonParams.InstanceStatus {
	inst, err := s.store.GetInstance(s.adminCtx, name)
	s.Require().NoError(err)
	return inst.Status
}

// forgeRunner builds the forge's view of one runner managed by this controller.
func (s *BusyRunnerReapSuite) ghRunner(id int64, name, status string, busy bool) *github.Runner {
	return &github.Runner{
		ID:     github.Ptr(id),
		Name:   github.Ptr(name),
		Status: github.Ptr(status),
		Busy:   github.Ptr(busy),
		Labels: []*github.RunnerLabels{
			{Name: github.Ptr(controllerLabelPrefix + ":" + s.mgr.controllerInfo.ControllerID.String())},
		},
	}
}

func (s *BusyRunnerReapSuite) forgeLists(runners ...*github.Runner) {
	s.ghcli.On("ListEntityRunners", mock.Anything, mock.Anything).
		Return(&github.Runners{TotalCount: len(runners), Runners: runners}, &github.Response{}, nil)
}

// ---------------------------------------------------------------------------
// Defect 1 — the incident. garm-eco5rkyctbsg: job started 1 minute after the
// runner came up, ran for 24 minutes, the forge reported the runner offline
// (busy), and the reap fired. It must not.
// ---------------------------------------------------------------------------

func (s *BusyRunnerReapSuite) TestBusyRunnerPastBootstrapTimeoutIsNotReaped() {
	s.newInstance("garm-busy", 10274, params.RunnerActive)
	s.age("garm-busy", 24*time.Minute)
	s.forgeLists(s.ghRunner(10274, "garm-busy", "offline", true))
	// What GitHub answers for a busy runner. Unpatched GARM calls it; the
	// patched tree must not even ask.
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(10274)).Return(runnerErrors.ErrBadRequest).Maybe()

	err := s.mgr.runnerCleanup()

	s.ghcli.AssertNotCalled(s.T(), "RemoveEntityRunner", mock.Anything, int64(10274))
	s.NoError(err, "a busy runner is not an error condition for the cleanup pass")
	s.Equal(commonParams.InstanceRunning, s.status("garm-busy"))
}

// ---------------------------------------------------------------------------
// Defect 2 — a runner the forge refuses to release stopped the whole pass:
// reapTimedOutRunners returned on the first failure and runnerCleanup then
// skipped cleanupOrphanedRunners for the entity. The orphan here is a runner
// the forge still lists (offline, idle) that GARM has no record of; only the
// orphan sweep removes it.
// ---------------------------------------------------------------------------

func (s *BusyRunnerReapSuite) TestRefusedReapDoesNotSkipOrphanSweep() {
	s.newInstance("garm-stuck", 5001, params.RunnerIdle)
	s.age("garm-stuck", 30*time.Minute)
	s.forgeLists(
		s.ghRunner(5001, "garm-stuck", "offline", false),
		s.ghRunner(5002, "garm-orphan", "offline", false),
	)
	// The forge fails this one removal (any reason other than "not found").
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(5001)).Return(runnerErrors.ErrBadRequest)
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(5002)).Return(nil).Maybe()
	// The orphan sweep also looks at garm-stuck (offline in the forge, a
	// record in the DB) and asks the provider about it; the provider still
	// has it running, so the sweep leaves it alone.
	s.provider.On("ListInstances", mock.Anything, s.pool.ID, mock.Anything).
		Return([]commonParams.ProviderInstance{{Name: "garm-stuck", Status: commonParams.InstanceRunning}}, nil).Maybe()

	err := s.mgr.runnerCleanup()

	s.Error(err, "the refused removal is still reported")
	s.ghcli.AssertCalled(s.T(), "RemoveEntityRunner", mock.Anything, int64(5002))
	s.Equal(commonParams.InstanceRunning, s.status("garm-stuck"),
		"a refused removal leaves the instance alone")
}

// ---------------------------------------------------------------------------
// Defect 3 — cleanupOrphanedProviderRunners destroyed an ACTIVE instance on
// the strength of one forge listing that did not contain it, with no age
// check and without asking the forge. The forge here still has the runner
// and is running a job on it (422 on removal).
// ---------------------------------------------------------------------------

func (s *BusyRunnerReapSuite) TestActiveRunnerMissingFromOneListingIsNotDestroyed() {
	s.newInstance("garm-unlisted", 7001, params.RunnerActive)
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(7001)).Return(runnerErrors.ErrBadRequest).Maybe()

	s.Require().NoError(s.mgr.cleanupOrphanedProviderRunners(nil))

	s.Equal(commonParams.InstanceRunning, s.status("garm-unlisted"),
		"an instance whose runner the forge will not release must not be marked for deletion")
}

// ---------------------------------------------------------------------------
// CONTROLS (must pass with AND without the patch): the patch must not stop
// GARM from retiring runners that really are finished or gone.
// ---------------------------------------------------------------------------

// A runner that never picked up a job (offline, idle) past the bootstrap
// timeout is still reaped.
func (s *BusyRunnerReapSuite) TestIdleOfflineRunnerPastTimeoutIsReaped() {
	s.newInstance("garm-dead", 6001, params.RunnerIdle)
	s.age("garm-dead", 25*time.Minute)
	s.forgeLists(s.ghRunner(6001, "garm-dead", "offline", false))
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(6001)).Return(nil)

	s.Require().NoError(s.mgr.runnerCleanup())

	s.ghcli.AssertCalled(s.T(), "RemoveEntityRunner", mock.Anything, int64(6001))
	s.Equal(commonParams.InstancePendingDelete, s.status("garm-dead"))
}

// An active runner the forge no longer has (its job finished while GARM
// missed the completed webhook) is still retired by the orphan sweep.
func (s *BusyRunnerReapSuite) TestActiveRunnerGoneFromForgeIsRetired() {
	s.newInstance("garm-finished", 8001, params.RunnerActive)
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(8001)).Return(runnerErrors.ErrNotFound).Maybe()

	s.Require().NoError(s.mgr.cleanupOrphanedProviderRunners(nil))

	s.Equal(commonParams.InstancePendingDelete, s.status("garm-finished"))
}

func TestBusyRunnerReapSuite(t *testing.T) {
	suite.Run(t, new(BusyRunnerReapSuite))
}
