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

package scaleset

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/go-github/v84/github"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"

	commonParams "github.com/cloudbase/garm-provider-common/params"
	"github.com/cloudbase/garm/cache"
	"github.com/cloudbase/garm/database"
	"github.com/cloudbase/garm/database/watcher"
	garmTesting "github.com/cloudbase/garm/internal/testing"
	"github.com/cloudbase/garm/params"
	"github.com/cloudbase/garm/runner/common/mocks"
)

const forgeScaleSetID = 4242

// TestWorkerStartSeesUpdateCommittedBeforeSubscribe reproduces a lost update
// between a scale set worker's initial load and its watcher subscription.
//
// The worker is built from a DISABLED scale set. While Start() is talking to
// the forge (ensureScaleSetInGitHub, which runs after the worker's state was
// loaded and before it registers its watcher consumer), the fake forge enables
// the scale set in the database. The update event is published before the
// worker is subscribed, so the worker never receives it, and enabling the set
// again later is a no-op that publishes nothing. Without a re-read after
// subscribing, the worker keeps Enabled=false in memory and never opens a
// message session.
func TestWorkerStartSeesUpdateCommittedBeforeSubscribe(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	watcher.InitWatcher(ctx)
	defer watcher.CloseWatcher()

	store, err := database.NewDatabase(ctx, garmTesting.GetTestSqliteDBConfig(t))
	require.NoError(t, err)
	_, err = store.InitController(ctx)
	require.NoError(t, err)
	adminCtx := garmTesting.ImpersonateAdminContext(ctx, store, t)

	endpoint := garmTesting.CreateDefaultGithubEndpoint(adminCtx, store, t)
	creds := garmTesting.CreateTestGithubCredentials(adminCtx, "test-creds", store, t, endpoint)
	org, err := store.CreateOrganization(adminCtx, "test-org", creds, "test-webhook-secret", params.PoolBalancerTypeRoundRobin, false)
	require.NoError(t, err)
	entity, err := org.GetEntity()
	require.NoError(t, err)

	scaleSet, err := store.CreateEntityScaleSet(adminCtx, entity, params.CreateScaleSetParams{
		Name:         "test-scaleset",
		ProviderName: "test-provider",
		MaxRunners:   1,
		Image:        "test-image",
		Flavor:       "test-flavor",
		OSType:       commonParams.Linux,
		OSArch:       commonParams.Amd64,
		ScaleSetID:   forgeScaleSetID,
		Enabled:      false,
	})
	require.NoError(t, err)
	require.False(t, scaleSet.Enabled)

	var raceInjected, sessionRequested atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
		switch {
		case req.Method == http.MethodPost && req.URL.Path == "/actions/runner-registration":
			_ = json.NewEncoder(rw).Encode(params.ActionsServiceAdminInfoResponse{
				URL:   "http://" + req.Host + "/pipeline",
				Token: "admin-token",
			})
		case req.Method == http.MethodGet && strings.HasSuffix(req.URL.Path, "/_apis/runtime/runnerscalesets"):
			// ensureScaleSetInGitHub() is between the worker's initial load
			// and its watcher subscription. Enable the scale set right now:
			// the update event is published to nobody.
			if raceInjected.CompareAndSwap(false, true) {
				enabled := true
				_, err := store.UpdateEntityScaleSet(adminCtx, entity, scaleSet.ID, params.UpdateScaleSetParams{Enabled: &enabled}, nil)
				if err != nil {
					t.Errorf("enabling scale set mid-start: %s", err)
				}
			}
			_ = json.NewEncoder(rw).Encode(params.RunnerScaleSetsResponse{
				Count:           1,
				RunnerScaleSets: []params.RunnerScaleSet{{ID: forgeScaleSetID, Name: "test-scaleset"}},
			})
		case req.Method == http.MethodPost && strings.HasSuffix(req.URL.Path, "/sessions"):
			// The listener only opens a session for an enabled scale set.
			// Refusing it keeps the listener retrying without any further
			// forge traffic.
			sessionRequested.Store(true)
			rw.WriteHeader(http.StatusServiceUnavailable)
		default:
			rw.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	baseURL, err := url.Parse(srv.URL)
	require.NoError(t, err)

	ghCli := &mocks.GithubClient{}
	ghCli.On("GetEntity").Return(entity).Maybe()
	ghCli.On("GithubBaseURL").Return(baseURL).Maybe()
	ghCli.On("CreateEntityRegistrationToken", mock.Anything).Return(&github.RegistrationToken{
		Token:     github.Ptr("registration-token"),
		ExpiresAt: &github.Timestamp{Time: time.Now().Add(time.Hour)},
	}, nil, nil).Maybe()
	ghCli.On("GetEntityRunnerGroupIDByName", mock.Anything, mock.Anything).Return(int64(1), nil).Maybe()
	cache.SetGithubClient(entity.ID, ghCli)
	defer cache.DeleteGithubClient(entity.ID)

	// The worker is built from the row as the controller loaded it: disabled.
	worker, err := NewWorker(adminCtx, store, scaleSet, nil)
	require.NoError(t, err)
	require.NoError(t, worker.Start())
	defer worker.Stop()

	require.True(t, raceInjected.Load(), "the update was not injected between the initial load and the subscription")
	dbScaleSet, err := store.GetScaleSetByID(adminCtx, scaleSet.ID)
	require.NoError(t, err)
	require.True(t, dbScaleSet.Enabled, "the scale set is not enabled in the database")

	// Report both symptoms: the stale in-memory copy, and the listener that
	// never opens a session because of it.
	worker.mux.Lock()
	enabled := worker.scaleSet.Enabled
	worker.mux.Unlock()
	assert.True(t, enabled, "worker kept a stale copy of the scale set: enabled in the database, disabled in the worker")

	assert.Eventually(t, sessionRequested.Load, 30*time.Second, 50*time.Millisecond,
		"the worker never opened a message session for its enabled scale set")
}
