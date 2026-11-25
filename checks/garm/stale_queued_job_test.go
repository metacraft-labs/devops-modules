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

// Gate t_garm_stale_queued_job_dropped — the pool manager must stop serving a
// queued job once it is older than GitHub's 24-hour queue limit.
//
// WHAT IS UNDER TEST
//
//	GARM's own basePoolManager.consumeQueuedJobs(), driven through GARM's
//	own pool stress suite (runner/pool/pool_test.go: PoolStressTestSuite,
//	the REAL sqlDatabase on a REAL SQLite file). Jobs enter through
//	HandleWorkflowJob, as a webhook would deliver them.
//
// MOCKS AND STAND-INS, AND WHY
//
//   - The forge client and the provider are the suite's own mocks
//     (setupProviderMocks): no github.com and no hypervisor in the sandbox.
//   - The job's age. The test backdates CreatedAt on the pool manager's
//     cached copy of the job, which is the copy consumeQueuedJobs reads
//     (the cache is otherwise fed from the store by the watcher). This is
//     the one stand-in, and it is not a mock: no behaviour is replaced, only
//     the clock reading on a real record, because a test cannot wait a day.
//
// THE PRODUCTION OBSERVATION (central GARM, high-mem-server, 2026-11-25)
//
//	garm-cli job list held 165 queued pool jobs created 2026-09-30 to
//	2026-11-23, every one from a workflow run that had already completed:
//	77 completed on GitHub with the completed event never recorded, 88 left
//	queued by GitHub inside finished runs. In a 30-minute window 1,476 of
//	2,917 runner-create attempts (51%) went to them. Upstream deletes only
//	non-queued jobs (DeleteInactionableJobs), so nothing ever removed them.
//	See infra issues/2026-11-25-garm-keeps-retrying-165-queued-jobs-whose-runs-ended-weeks-ago.md.
//
// WHY IT DISCRIMINATES
//
//	checks/t_garm_stale_queued_job_dropped.sh runs this file against the
//	tree this repo ships (all pass) and against the same tree minus
//	expire-stale-queued-jobs.patch (the defect test fails, the control
//	passes). The file references no symbol the patch introduces.
package pool

import (
	"time"

	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/params"
)

// cacheJobsByRecordID loads the store's jobs into the manager's cache keyed
// the way production keys it (the job record's own ID, see watcher.go),
// with the given job's CreatedAt moved back by age.
func (s *PoolStressTestSuite) cacheJobsByRecordID(backdate int64, age time.Duration) {
	all, err := s.store.ListAllJobs(s.adminCtx)
	s.Require().NoError(err)
	s.mgr.mux.Lock()
	defer s.mgr.mux.Unlock()
	for k := range s.mgr.jobs {
		delete(s.mgr.jobs, k)
	}
	for _, j := range all {
		if j.WorkflowJobID == backdate {
			j.CreatedAt = time.Now().Add(-age)
		}
		s.mgr.jobs[j.ID] = j
	}
}

func (s *PoolStressTestSuite) fillPoolToOne() {
	maxRunners := uint(1)
	minIdle := uint(1)
	pool, err := s.store.UpdateEntityPool(s.adminCtx, s.entity, s.pool.ID, params.UpdatePoolParams{
		MaxRunners:     &maxRunners,
		MinIdleRunners: &minIdle,
	})
	s.Require().NoError(err)
	s.pool = pool
	cache.SetEntityPool(s.entity.ID, pool)
	s.Require().NoError(s.mgr.ensureIdleRunnersForOnePool(pool))
}

func (s *PoolStressTestSuite) queuedJobIDs() map[int64]bool {
	queued, err := s.store.ListJobsByStatus(s.adminCtx, params.JobStatusQueued)
	s.Require().NoError(err)
	ids := map[int64]bool{}
	for _, j := range queued {
		ids[j.WorkflowJobID] = true
	}
	return ids
}

// Defect: a job queued for longer than GitHub's limit is dropped from the
// store and from the cache. The fresh job next to it is left alone.
func (s *PoolStressTestSuite) TestStaleQueuedJobIsDropped() {
	s.setupProviderMocks()
	s.fillPoolToOne()
	labels := []string{"self-hosted", "linux", "x64"}
	s.Require().NoError(s.mgr.HandleWorkflowJob(s.makeWorkflowJob(9001, "queued", "queued", "", labels)))
	s.Require().NoError(s.mgr.HandleWorkflowJob(s.makeWorkflowJob(9002, "queued", "queued", "", labels)))
	s.mgr.controllerInfo.MinimumJobAgeBackoff = 0
	s.cacheJobsByRecordID(9001, 25*time.Hour)

	s.Require().NoError(s.mgr.consumeQueuedJobs())

	ids := s.queuedJobIDs()
	s.False(ids[9001], "a job queued for 25 hours is still in the store")
	s.True(ids[9002], "a fresh queued job must stay queued")
	for _, j := range s.mgr.getQueuedJobs() {
		s.NotEqual(int64(9001), j.WorkflowJobID, "the stale job is still in the cache")
	}
}

// Control (passes with and without the patch): a job queued for less than
// the limit stays queued.
func (s *PoolStressTestSuite) TestQueuedJobUnderTheLimitIsKept() {
	s.setupProviderMocks()
	s.fillPoolToOne()
	labels := []string{"self-hosted", "linux", "x64"}
	s.Require().NoError(s.mgr.HandleWorkflowJob(s.makeWorkflowJob(9101, "queued", "queued", "", labels)))
	s.mgr.controllerInfo.MinimumJobAgeBackoff = 0
	s.cacheJobsByRecordID(9101, 23*time.Hour)

	s.Require().NoError(s.mgr.consumeQueuedJobs())

	s.True(s.queuedJobIDs()[9101], "a job queued for 23 hours must stay queued")
}
