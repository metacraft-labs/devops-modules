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

// Gate t_garm_job_started_runner_not_reaped — GARM's timeout reaper must not
// try to retire a runner that GARM itself recorded picking up a job.
//
// WHAT IS UNDER TEST
//
//	GARM's own basePoolManager.runnerCleanup() (list the forge's runners,
//	reapTimedOutRunners, cleanupOrphanedRunners) and
//	cleanupOrphanedProviderRunners(), against the REAL sqlDatabase on a REAL
//	SQLite file. The runner list comes through GARM's own
//	listRunnersWithPagination(), as in production.
//
// MOCKS, AND WHY EACH ONE IS NEEDED
//
//   - The forge client (runner/common/mocks.GithubClient). The property is
//     about what GARM does with one particular forge ANSWER — a runner that
//     is running a job, listed "offline" and NOT busy — and a sandbox has no
//     github.com, nor a way to make it give that answer on demand. The 422 it
//     returns on removal is runnerErrors.ErrBadRequest, which is what
//     util/github maps GitHub's 422 to.
//   - The provider (runner/common/mocks.Provider) is registered but must not
//     be called: nothing here should reach a hypervisor.
//
// THE PRODUCTION OBSERVATION (central GARM, high-mem-server, 2026-11-25)
//
//	agent-harbor runners garm-uwwowudkjqzx and garm-zvlbzkhlbykk were each
//	several hours into "Build Windows installers (x64)" (job timeout 1080
//	min). GARM's runner-liveness export (mcl_github_runner_online/_busy)
//	shows GitHub listing both offline AND not busy at 03:02Z; the timeout
//	reaper then asked GitHub to remove them, and GitHub refused with 422
//	("invalid request") because the jobs were still assigned. It recurred
//	at 05:10Z. fix-busy-runner-reap.patch only consults the forge's busy
//	flag, which is exactly what flickered. GARM's own record — the instance
//	went RunnerActive on the job's in_progress event — never did.
//
// WHY IT DISCRIMINATES
//
//	checks/t_garm_job_started_runner_not_reaped.sh runs this file against the
//	tree this repo ships (all pass) and against the same tree minus
//	fix-reap-skips-job-started-runners.patch (the defect test fails with the
//	removal-attempt signature; the controls pass). The file references no
//	symbol the patch introduces.
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

type JobStartedRunnerReapSuite struct {
	suite.Suite

	dbCfg    config.Database
	store    dbCommon.Store
	adminCtx context.Context
	pool     params.Pool
	mgr      *basePoolManager
	provider *runnerCommonMocks.Provider
	ghcli    *runnerCommonMocks.GithubClient
}

func (s *JobStartedRunnerReapSuite) SetupTest() {
	s.dbCfg = garmTesting.GetTestSqliteDBConfig(s.T())
	db, err := database.NewDatabase(context.Background(), s.dbCfg)
	s.Require().NoError(err)
	s.store = db
	s.adminCtx = garmTesting.ImpersonateAdminContext(context.Background(), db, s.T())

	endpoint := garmTesting.CreateDefaultGithubEndpoint(s.adminCtx, db, s.T())
	creds := garmTesting.CreateTestGithubCredentials(s.adminCtx, "job-started-reap-creds", db, s.T(), endpoint)
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
		consumerID:       "job-started-reap-consumer",
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
func (s *JobStartedRunnerReapSuite) newInstance(name string, agentID int64, rs params.RunnerStatus) {
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
func (s *JobStartedRunnerReapSuite) age(name string, by time.Duration) {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()
	res, err := conn.Exec("UPDATE instances SET updated_at = ? WHERE name = ?", time.Now().Add(-by), name)
	s.Require().NoError(err)
	n, err := res.RowsAffected()
	s.Require().NoError(err)
	s.Require().EqualValues(1, n)
}

func (s *JobStartedRunnerReapSuite) status(name string) commonParams.InstanceStatus {
	inst, err := s.store.GetInstance(s.adminCtx, name)
	s.Require().NoError(err)
	return inst.Status
}

// forgeRunner builds the forge's view of one runner managed by this controller.
func (s *JobStartedRunnerReapSuite) ghRunner(id int64, name, status string, busy bool) *github.Runner {
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

func (s *JobStartedRunnerReapSuite) forgeLists(runners ...*github.Runner) {
	s.ghcli.On("ListEntityRunners", mock.Anything, mock.Anything).
		Return(&github.Runners{TotalCount: len(runners), Runners: runners}, &github.Response{}, nil)
}

// ---------------------------------------------------------------------------
// Defect — the incident: a runner that started a job, listed offline and not
// busy past the bootstrap timeout, must not be handed to DeleteRunner.
// ---------------------------------------------------------------------------

func (s *JobStartedRunnerReapSuite) TestJobStartedRunnerListedOfflineIdleIsNotReaped() {
	s.newInstance("garm-building", 30042, params.RunnerActive)
	s.age("garm-building", 6*time.Hour)
	s.forgeLists(s.ghRunner(30042, "garm-building", "offline", false))
	// What GitHub answers while the job is still assigned. The patched tree
	// must not even ask.
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(30042)).Return(runnerErrors.ErrBadRequest).Maybe()
	// The orphan sweep looks at an offline runner that has a DB record and
	// asks the provider about it; the provider still has it running.
	s.provider.On("ListInstances", mock.Anything, s.pool.ID, mock.Anything).
		Return([]commonParams.ProviderInstance{{Name: "garm-building", Status: commonParams.InstanceRunning}}, nil).Maybe()

	err := s.mgr.runnerCleanup()

	s.ghcli.AssertNotCalled(s.T(), "RemoveEntityRunner", mock.Anything, int64(30042))
	s.NoError(err, "a runner that is running a job is not an error condition for the cleanup pass")
	s.Equal(commonParams.InstanceRunning, s.status("garm-building"))
}

// ---------------------------------------------------------------------------
// CONTROLS (must pass with AND without the patch).
// ---------------------------------------------------------------------------

// A runner that never picked up a job (idle, offline) past the bootstrap
// timeout is still reaped: the guard is about RunnerActive only.
func (s *JobStartedRunnerReapSuite) TestIdleOfflineRunnerPastTimeoutIsReaped() {
	s.newInstance("garm-dead", 6001, params.RunnerIdle)
	s.age("garm-dead", 25*time.Minute)
	s.forgeLists(s.ghRunner(6001, "garm-dead", "offline", false))
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(6001)).Return(nil)

	s.Require().NoError(s.mgr.runnerCleanup())

	s.ghcli.AssertCalled(s.T(), "RemoveEntityRunner", mock.Anything, int64(6001))
	s.Equal(commonParams.InstancePendingDelete, s.status("garm-dead"))
}

// A runner whose JIT registration never reached the forge (pending, absent
// from the listing) past the bootstrap timeout is still reaped.
func (s *JobStartedRunnerReapSuite) TestNeverJoinedRunnerPastTimeoutIsReaped() {
	s.newInstance("garm-never-joined", 6002, params.RunnerPending)
	s.age("garm-never-joined", 25*time.Minute)
	s.forgeLists()
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(6002)).Return(runnerErrors.ErrNotFound).Maybe()

	s.Require().NoError(s.mgr.runnerCleanup())

	s.Equal(commonParams.InstancePendingDelete, s.status("garm-never-joined"))
}

// A runner that started a job and that the forge no longer has (the job
// ended and GARM missed the completed event) is still retired, by the orphan
// sweep rather than the reaper.
func (s *JobStartedRunnerReapSuite) TestJobStartedRunnerGoneFromForgeIsRetired() {
	s.newInstance("garm-finished", 8001, params.RunnerActive)
	s.ghcli.On("RemoveEntityRunner", mock.Anything, int64(8001)).Return(runnerErrors.ErrNotFound).Maybe()

	s.Require().NoError(s.mgr.cleanupOrphanedProviderRunners(nil))

	s.Equal(commonParams.InstancePendingDelete, s.status("garm-finished"))
}

func TestJobStartedRunnerReapSuite(t *testing.T) {
	suite.Run(t, new(JobStartedRunnerReapSuite))
}
