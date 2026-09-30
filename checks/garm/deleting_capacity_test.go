//go:build testing

// Gate test for packages/garm/patches/fix-deleting-instances-hold-capacity.patch,
// copied into runner/pool/ of both the patched tree and the negative control
// by checks/t_garm_deleting_capacity.sh. It extends the upstream
// PoolStressTestSuite (runner/pool/pool_test.go), which runs against a REAL
// sqlite store, so the database's own MaxRunners check in CreateInstance is
// exercised, not stubbed.
//
// Mocks, and why: the suite's provider and GitHub client are mockery mocks
// (setupProviderMocks). This test only creates DB rows through the pool
// manager and never reaches a provider; creating real runners would need a
// hypervisor and GitHub. Everything under test (the pool manager's and the
// database's capacity accounting) is real.
package pool

import (
	commonParams "github.com/cloudbase/garm-provider-common/params"
	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/params"
)

// Instances whose provider delete keeps failing (observed: incus `zfs destroy`
// returning "dataset is busy" for hours) stay in the table on the deletion
// lane. They must not use up the pool's MaxRunners, or the pool has no runners
// left. The exemption is bounded, so a provider that never completes a delete
// cannot make the pool create without limit.
func (s *PoolStressTestSuite) TestStuckDeletesDoNotConsumePoolCapacity() {
	s.setupProviderMocks()

	maxRunners := uint(2)
	minIdle := uint(2)
	pool, err := s.store.UpdateEntityPool(s.adminCtx, s.entity, s.pool.ID, params.UpdatePoolParams{
		MaxRunners:     &maxRunners,
		MinIdleRunners: &minIdle,
	})
	s.Require().NoError(err)
	cache.SetEntityPool(s.entity.ID, pool)

	markAll := func(status commonParams.InstanceStatus) {
		instances, err := s.store.ListPoolInstances(s.adminCtx, pool.ID, false)
		s.Require().NoError(err)
		for _, inst := range instances {
			if inst.Status == commonParams.InstancePendingDelete || inst.Status == commonParams.InstanceDeleting {
				continue
			}
			_, err := s.store.UpdateInstance(s.adminCtx, inst.Name, params.UpdateInstanceParams{Status: status})
			s.Require().NoError(err)
		}
	}
	count := func() int {
		instances, err := s.store.ListPoolInstances(s.adminCtx, pool.ID, false)
		s.Require().NoError(err)
		return len(instances)
	}

	s.Require().NoError(s.mgr.ensureIdleRunnersForOnePool(pool))
	s.Require().Equal(2, count())

	// Both runners finish their jobs and their deletes get stuck.
	markAll(commonParams.InstancePendingDelete)
	s.Require().NoError(s.mgr.ensureIdleRunnersForOnePool(pool))
	s.Equal(4, count(), "stuck deletes must not block min-idle replenishment")

	// A pending_delete row with runner status `pending` is not an idle runner.
	s.Require().NoError(s.mgr.ensureIdleRunnersForOnePool(pool))
	s.Equal(4, count(), "no extra runners once the live ones satisfy min-idle")

	// The replacements' deletes get stuck too. MaxRunners of stuck rows are
	// exempt, the rest count, so the pool is now full.
	markAll(commonParams.InstancePendingDelete)
	s.Require().NoError(s.mgr.ensureIdleRunnersForOnePool(pool))
	s.Equal(4, count(), "the provider footprint is bounded at 2 x MaxRunners")
	err = s.mgr.addRunnerToPool(pool, nil)
	s.Require().Error(err, "addRunnerToPool must refuse past the bound")
}
