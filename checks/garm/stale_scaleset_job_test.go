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

// Gate t_garm_stale_scaleset_job_reaped (milestone H3 of
// docs/Host-Stability-Recovery.milestones.org in metacraft-labs/infra).
//
// WHAT IS UNDER TEST
//
//	GARM's OWN stale-job reconciler — basePoolManager.reconcileStaleJobs(),
//	driven both directly and through the real startLoopForFunction() loop
//	that runner startup wires it into. Nothing about the reaper is
//	re-implemented here.
//
//	The store is the REAL sqlDatabase on a REAL SQLite file (the same
//	database/sql package the daemon uses, same DSN, same schema). The only
//	mocked boundary is the forge: GetWorkflowRunByID / GetWorkflowJobByID are
//	served by the generated GithubClient mock, because the alternative is
//	talking to github.com from a hermetic build sandbox.
//
//	The fixture reproduces the live phantom on high-mem-server exactly:
//	an org-scoped job row created by the scale set listener's own
//	recordOrUpdateJob() shape — workflow_job_id = 0, scale_set_job_id set,
//	status "queued", no runner_name — whose GitHub run has since completed.
//
// WHY IT DISCRIMINATES
//
//	Run the same file against the UNPATCHED tree (the negative control, see
//	checks/t_garm_stale_scaleset_job_reaped.sh) and TestStaleScaleSetJob*
//	fail: ListEntityJobsByStatus hard-filters `workflow_job_id > 0`, so the
//	candidate list is empty, the forge is never consulted, and the row is
//	still there afterwards.
package pool

import (
	"context"
	"database/sql"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/google/go-github/v84/github"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/suite"

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

const (
	// The identifiers of the live phantom, carried verbatim so the fixture
	// cannot silently drift away from the thing it stands for.
	phantomScaleSetJobID = "1dc51c41-b4c4-536b-955f-0917622abcec"
	phantomRunID         = int64(32128763123)
	phantomJobName       = "Cross-Repo Tests"
	phantomRepoOwner     = "metacraft-labs"
	phantomRepoName      = "codetracer-ci"
)

func init() {
	// reconcileStaleJobs takes the same advisory lock the daemon takes.
	// cmd/garm registers the local locker at startup; do the same here so the
	// real code path runs rather than a stubbed one. Ignore "already
	// registered" — another test file in this package may have got there
	// first.
	lock, err := locking.NewLocalLocker(context.Background(), nil)
	if err != nil {
		panic(err)
	}
	_ = locking.RegisterLocker(lock)
}

type StaleScaleSetJobSuite struct {
	suite.Suite

	dbCfg     config.Database
	store     dbCommon.Store
	adminCtx  context.Context
	creds     params.ForgeCredentials
	entity    params.ForgeEntity
	mgr       *basePoolManager
	ghcliMock *runnerCommonMocks.GithubClient
}

func (s *StaleScaleSetJobSuite) SetupTest() {
	s.dbCfg = garmTesting.GetTestSqliteDBConfig(s.T())
	db, err := database.NewDatabase(context.Background(), s.dbCfg)
	s.Require().NoError(err)

	s.store = db
	s.adminCtx = garmTesting.ImpersonateAdminContext(context.Background(), db, s.T())

	endpoint := garmTesting.CreateDefaultGithubEndpoint(s.adminCtx, db, s.T())
	creds := garmTesting.CreateTestGithubCredentials(s.adminCtx, "stale-creds", db, s.T(), endpoint)
	s.creds = creds

	// An ORGANIZATION entity, because that is what serves scale sets in
	// production (the live phantom hangs off org metacraft-labs).
	org, err := db.CreateOrganization(
		s.adminCtx,
		phantomRepoOwner,
		creds,
		"test-webhook-secret",
		params.PoolBalancerTypeRoundRobin,
		false,
	)
	s.Require().NoError(err)

	entity, err := org.GetEntity()
	s.Require().NoError(err)
	s.entity = entity
	cache.SetEntity(entity)

	controllerInfo, err := db.InitController()
	s.Require().NoError(err)

	backoff, err := locking.NewInstanceDeleteBackoff(context.Background())
	s.Require().NoError(err)

	s.ghcliMock = runnerCommonMocks.NewGithubClient(s.T())

	s.mgr = &basePoolManager{
		ctx:              s.adminCtx,
		consumerID:       "stale-job-test-consumer",
		entity:           entity,
		store:            db,
		controllerInfo:   controllerInfo,
		providers:        map[string]common.Provider{},
		jobs:             make(map[int64]params.Job),
		checkedJobs:      make(map[int64]time.Time),
		quit:             make(chan struct{}),
		consumer:         &garmTesting.MockConsumer{},
		wg:               &sync.WaitGroup{},
		backoff:          backoff,
		ghcli:            s.ghcliMock,
		managerIsRunning: true,
	}
}

// recordScaleSetJob inserts a job row the way the scale set listener does:
// via the store's CreateOrUpdateJob, with a ScaleSetJobID and NO
// WorkflowJobID. Nothing here writes SQL by hand.
func (s *StaleScaleSetJobSuite) recordScaleSetJob(scaleSetJobID string, runID int64, name, status string) params.Job {
	orgID, err := s.entity.GetIDAsUUID()
	s.Require().NoError(err)

	job, err := s.store.CreateOrUpdateJob(s.adminCtx, params.Job{
		ScaleSetJobID:   scaleSetJobID,
		RunID:           runID,
		Action:          "push",
		Status:          status,
		Name:            name,
		RunnerGroupName: "Default",
		RepositoryName:  phantomRepoName,
		RepositoryOwner: phantomRepoOwner,
		Labels:          []string{"eph-linux-x64"},
		OrgID:           &orgID,
	})
	s.Require().NoError(err)
	s.Require().Zero(job.WorkflowJobID, "fixture must reproduce a scale set job: workflow_job_id MUST be 0")
	s.Require().NotZero(job.ID, "every job row has a primary key, both kinds")
	return job
}

// recordPoolJob inserts an ordinary webhook/pool job row (workflow_job_id > 0)
// so the patch can be shown not to have broken the pre-existing path.
func (s *StaleScaleSetJobSuite) recordPoolJob(workflowJobID, runID int64, status string) params.Job {
	orgID, err := s.entity.GetIDAsUUID()
	s.Require().NoError(err)

	job, err := s.store.CreateOrUpdateJob(s.adminCtx, params.Job{
		WorkflowJobID:   workflowJobID,
		RunID:           runID,
		Action:          "push",
		Status:          status,
		Name:            fmt.Sprintf("pool-job-%d", workflowJobID),
		RepositoryName:  phantomRepoName,
		RepositoryOwner: phantomRepoOwner,
		Labels:          []string{"self-hosted"},
		OrgID:           &orgID,
	})
	s.Require().NoError(err)
	return job
}

// ageJob backdates a row's created_at. The reaper only considers candidates
// older than an hour, and a test must not sleep for one. This is the ONLY
// direct SQL in the gate and it touches nothing the reaper reads except the
// timestamp it is documented to gate on.
func (s *StaleScaleSetJobSuite) ageJob(id int64, age time.Duration) {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()

	res, err := conn.Exec(
		"UPDATE workflow_jobs SET created_at = ?, updated_at = ? WHERE id = ?",
		time.Now().Add(-age), time.Now().Add(-age), id)
	s.Require().NoError(err)
	affected, err := res.RowsAffected()
	s.Require().NoError(err)
	s.Require().EqualValues(1, affected, "ageJob must age exactly one row")
}

func (s *StaleScaleSetJobSuite) countRows(status string) int {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()

	var n int
	s.Require().NoError(conn.QueryRow(
		"SELECT count(*) FROM workflow_jobs WHERE deleted_at IS NULL AND status = ?", status).Scan(&n))
	return n
}

func (s *StaleScaleSetJobSuite) rowExists(id int64) bool {
	conn, err := sql.Open("sqlite3", s.dbCfg.SQLite.DBFile)
	s.Require().NoError(err)
	defer conn.Close()

	var n int
	s.Require().NoError(conn.QueryRow(
		"SELECT count(*) FROM workflow_jobs WHERE deleted_at IS NULL AND id = ?", id).Scan(&n))
	return n == 1
}

func completedRun(runID int64) *github.WorkflowRun {
	return &github.WorkflowRun{
		ID:         github.Ptr(runID),
		Status:     github.Ptr("completed"),
		Conclusion: github.Ptr("failure"),
	}
}

func liveRun(runID int64) *github.WorkflowRun {
	return &github.WorkflowRun{
		ID:     github.Ptr(runID),
		Status: github.Ptr("in_progress"),
	}
}

// ---------------------------------------------------------------------------
// 1. THE CANDIDATE FILTER — the first upstream gap.
//
// ListEntityJobsByStatus is what reconcileStaleJobs selects candidates with.
// On the unpatched tree it hard-filters `workflow_job_id > 0`, so a scale set
// job can never appear in it and the reaper is a no-op for the entire
// installation. On high-mem-server every one of the 9 rows in the live
// workflow_jobs table carries workflow_job_id = 0.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestStaleScaleSetJobIsACandidate() {
	phantom := s.recordScaleSetJob(phantomScaleSetJobID, phantomRunID, phantomJobName, "queued")

	queued, err := s.store.ListEntityJobsByStatus(
		s.adminCtx, s.entity.EntityType, s.entity.ID, params.JobStatusQueued)
	s.Require().NoError(err)

	var found bool
	for _, j := range queued {
		if j.ID == phantom.ID {
			found = true
			s.Require().Equal(phantomScaleSetJobID, j.ScaleSetJobID)
			s.Require().Zero(j.WorkflowJobID)
		}
	}
	s.Require().True(found,
		"a queued scale set job MUST appear in the reconciler's candidate list; got %d candidates", len(queued))
}

// ---------------------------------------------------------------------------
// 2. THE MECHANISM — one pass of GARM's own reaper clears the phantom.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestStaleScaleSetJobReapedInOnePass() {
	phantom := s.recordScaleSetJob(phantomScaleSetJobID, phantomRunID, phantomJobName, "queued")
	s.ageJob(phantom.ID, 26*time.Hour)

	s.Require().Equal(1, s.countRows("queued"))

	// The forge says the run has completed. That is the whole input.
	s.ghcliMock.On("GetWorkflowRunByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, phantomRunID,
	).Return(completedRun(phantomRunID), &github.Response{}, nil).Once()

	s.Require().NoError(s.mgr.reconcileStaleJobs())

	s.Require().False(s.rowExists(phantom.ID),
		"one reconcile pass MUST clear a scale set job whose run has completed")
	s.Require().Equal(0, s.countRows("queued"))
	s.ghcliMock.AssertNumberOfCalls(s.T(), "GetWorkflowRunByID", 1)
}

// ---------------------------------------------------------------------------
// 3. THE SAFETY PROPERTY — a genuinely queued scale set job is NOT reaped.
//
// This is the half that makes the gate worth having: the operator wants the
// queue signal, so a reaper that clears real backlog is worse than the
// phantom. Modelled on the two rows that were legitimately queued on
// high-mem-server at the time of writing (run 32506577130, lint-bash and
// lint-nix, both queued on GitHub).
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestGenuinelyQueuedScaleSetJobSurvives() {
	live := s.recordScaleSetJob("4d42489c-169e-5f18-851b-0918d8f97796", 32506577130, "lint-bash", "queued")
	s.ageJob(live.ID, 26*time.Hour)

	s.ghcliMock.On("GetWorkflowRunByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, int64(32506577130),
	).Return(liveRun(32506577130), &github.Response{}, nil).Once()

	s.Require().NoError(s.mgr.reconcileStaleJobs())

	s.Require().True(s.rowExists(live.ID),
		"a scale set job whose run is still in_progress MUST NOT be reaped")
	s.Require().Equal(1, s.countRows("queued"))
}

// ---------------------------------------------------------------------------
// 4. NO COLLATERAL DAMAGE — the second upstream gap.
//
// store.DeleteJob() resolves rows with `WHERE workflow_job_id = ?` and takes
// First(). Every scale set row has workflow_job_id = 0, so a reaper that
// deletes by WorkflowJobID passes 0 and gorm hands it whichever such row has
// the LOWEST primary key — not the row it meant to delete. Here three scale
// set jobs share workflow_job_id = 0; exactly one is stale; the other two must
// survive untouched, and one of them is in_progress (i.e. a runner is
// executing it right now).
//
// FIXTURE ORDER IS LOAD-BEARING. The stale row is inserted LAST, so it does
// NOT have the lowest id. Insert it first and a DeleteJob(ctx, 0) would delete
// the right row by coincidence and this test would pass against the very
// defect it exists to catch — verified by mutation: reverting only
// `DeleteJobByID(job.ID)` to `DeleteJob(job.WorkflowJobID)` passes with the
// stale row first and fails with it last.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestReapingIsRowAccurate() {
	otherQueued := s.recordScaleSetJob("4d42489c-169e-5f18-851b-0918d8f97796", 32506577130, "lint-bash", "queued")
	running := s.recordScaleSetJob("e2ddc0c9-5fb9-5ffd-971e-5953e944cd23", 32308427204, "windows-x64", "in_progress")
	stale := s.recordScaleSetJob(phantomScaleSetJobID, phantomRunID, phantomJobName, "queued")

	s.Require().Less(otherQueued.ID, stale.ID,
		"fixture invariant: the stale row must NOT be the lowest-id scale set row")

	s.ageJob(stale.ID, 26*time.Hour)
	s.ageJob(otherQueued.ID, 26*time.Hour)
	s.ageJob(running.ID, 26*time.Hour)

	s.ghcliMock.On("GetWorkflowRunByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, phantomRunID,
	).Return(completedRun(phantomRunID), &github.Response{}, nil).Once()
	s.ghcliMock.On("GetWorkflowRunByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, int64(32506577130),
	).Return(liveRun(32506577130), &github.Response{}, nil).Once()

	s.Require().NoError(s.mgr.reconcileStaleJobs())

	s.Require().False(s.rowExists(stale.ID), "the stale row must go")
	s.Require().True(s.rowExists(otherQueued.ID), "a live queued sibling must survive")
	s.Require().True(s.rowExists(running.ID), "an in_progress sibling must survive")
	s.Require().Equal(1, s.countRows("queued"))
	s.Require().Equal(1, s.countRows("in_progress"))
}

// ---------------------------------------------------------------------------
// 4b. ENTITY ISOLATION — the relaxed filter must not widen the entity scope.
//
// The new predicate is the only OR in a WHERE clause that is otherwise a
// conjunction: `status = ?` AND (`workflow_job_id > 0` OR `scale_set_job_id
// <> ''`) AND `org_id = ?`. If those parentheses are ever lost — a gorm
// version that stops wrapping a raw Expr containing " OR ", or a future edit
// that inlines the clause differently — SQL precedence turns it into
// `(status = ? AND workflow_job_id > 0) OR (scale_set_job_id <> '' AND
// org_id = ?)`, whose FIRST disjunct is not scoped to the entity at all. A
// controller that serves several organisations would then hand one entity's
// reconciler another entity's rows to condemn. That is a silent, cross-tenant
// delete, so it is asserted rather than trusted.
//
// The fixture is chosen to discriminate: a queued, aged POOL job (which
// satisfies `status = 'queued' AND workflow_job_id > 0`) belonging to a
// DIFFERENT organisation. Under correct parenthesisation it is invisible to
// this entity; under the broken form it would be a candidate.
//
// This passes on the unpatched tree too — the unpatched filter is a plain
// conjunct — which is the point: it guards the property the patch must not
// break, not the behaviour the patch adds.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestAnotherEntitysJobIsNotACandidate() {
	otherOrg, err := s.store.CreateOrganization(
		s.adminCtx,
		"other-org",
		s.creds,
		"test-webhook-secret",
		params.PoolBalancerTypeRoundRobin,
		false,
	)
	s.Require().NoError(err)
	otherEntity, err := otherOrg.GetEntity()
	s.Require().NoError(err)
	otherOrgID, err := otherEntity.GetIDAsUUID()
	s.Require().NoError(err)

	foreign, err := s.store.CreateOrUpdateJob(s.adminCtx, params.Job{
		WorkflowJobID:   95685047649,
		RunID:           phantomRunID,
		Action:          "push",
		Status:          "queued",
		Name:            "foreign-pool-job",
		RepositoryName:  phantomRepoName,
		RepositoryOwner: phantomRepoOwner,
		Labels:          []string{"self-hosted"},
		OrgID:           &otherOrgID,
	})
	s.Require().NoError(err)
	s.Require().NotZero(foreign.WorkflowJobID,
		"fixture must satisfy the first disjunct, or it cannot discriminate")
	s.ageJob(foreign.ID, 26*time.Hour)

	queued, err := s.store.ListEntityJobsByStatus(
		s.adminCtx, s.entity.EntityType, s.entity.ID, params.JobStatusQueued)
	s.Require().NoError(err)
	for _, j := range queued {
		s.Require().NotEqual(foreign.ID, j.ID,
			"another entity's job MUST NOT appear in this entity's candidate list")
	}

	// And the reconciler must leave it alone: no forge call is expected, so an
	// unexpected one fails the mock, and the row must still be there after.
	s.Require().NoError(s.mgr.reconcileStaleJobs())
	s.Require().True(s.rowExists(foreign.ID),
		"another entity's job MUST survive this entity's reconcile pass")
}

// ---------------------------------------------------------------------------
// 5. NO REGRESSION for ordinary webhook/pool jobs.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestPoolJobStillReapedByWorkflowJobID() {
	poolJob := s.recordPoolJob(95685047648, 32128763123, "queued")
	s.ageJob(poolJob.ID, 26*time.Hour)

	s.ghcliMock.On("GetWorkflowJobByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, int64(95685047648),
	).Return(&github.WorkflowJob{Status: github.Ptr("completed")}, &github.Response{}, nil).Once()

	s.Require().NoError(s.mgr.reconcileStaleJobs())

	s.Require().False(s.rowExists(poolJob.ID),
		"a stale pool job must still be reaped through the workflow-job path")
	s.ghcliMock.AssertNumberOfCalls(s.T(), "GetWorkflowRunByID", 0)
}

// ---------------------------------------------------------------------------
// 6. THE SCHEDULE — "within the reconcile interval".
//
// The reaper is driven through the REAL startLoopForFunction(), the same
// helper runner startup uses, so the loop wiring itself is exercised rather
// than asserted about. The interval used here is compressed; that the
// PRODUCTION interval is 5 minutes and that reconcileStaleJobs is the
// function wired into it is asserted separately and statically by
// checks/t_garm_stale_scaleset_job_reaped.sh against pool.go and
// runner/common/pool.go.
//
// The assertion is on a COUNT (the row is gone after the loop has been
// allowed to tick), not on elapsed time: this gate runs on a host whose I/O
// stalls for minutes at a time, so no wall-clock figure here would mean
// anything. The go test binary's own -timeout is the hang guard.
// ---------------------------------------------------------------------------

func (s *StaleScaleSetJobSuite) TestReapedByTheRealLoop() {
	phantom := s.recordScaleSetJob(phantomScaleSetJobID, phantomRunID, phantomJobName, "queued")
	s.ageJob(phantom.ID, 26*time.Hour)

	reaped := make(chan struct{})
	var once sync.Once
	s.ghcliMock.On("GetWorkflowRunByID",
		mock.Anything, phantomRepoOwner, phantomRepoName, phantomRunID,
	).Return(completedRun(phantomRunID), &github.Response{}, nil).Run(func(mock.Arguments) {
		once.Do(func() { close(reaped) })
	})

	go s.mgr.startLoopForFunction(s.mgr.reconcileStaleJobs, 50*time.Millisecond, "stale_job_reconciler", false)
	defer close(s.mgr.quit)

	<-reaped
	// The delete happens after the call returns; wait for the loop to settle
	// by observing the row, bounded by the test binary's own timeout.
	for s.rowExists(phantom.ID) {
		time.Sleep(10 * time.Millisecond)
	}
	s.Require().False(s.rowExists(phantom.ID))
}

func TestStaleScaleSetJobSuite(t *testing.T) {
	t.Parallel()
	suite.Run(t, new(StaleScaleSetJobSuite))
}
