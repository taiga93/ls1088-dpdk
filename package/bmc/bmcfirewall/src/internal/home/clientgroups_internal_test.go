// BMC_CODE START
package home

import (
	"net/http"
	"testing"

	"github.com/AdguardTeam/AdGuardHome/internal/client"
	"github.com/AdguardTeam/AdGuardHome/internal/filtering"
	"github.com/AdguardTeam/AdGuardHome/internal/schedule"
	"github.com/AdguardTeam/golibs/testutil"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newGroupTestClient(
	tb testing.TB,
	name string,
	mac string,
	useOwn bool,
	services []string,
	sch *schedule.Weekly,
) *client.Persistent {
	tb.Helper()

	cli := newPersistentClientWithIDs(tb, name, []string{mac})
	cli.UseOwnBlockedServices = useOwn
	cli.BlockedServices = &filtering.BlockedServices{
		Schedule: sch,
		IDs:      services,
	}

	return cli
}

func requireGroupErrorStatus(tb testing.TB, want int, err error) {
	tb.Helper()

	groupErr := &blockedServiceGroupError{}
	require.ErrorAs(tb, err, &groupErr)
	assert.Equal(tb, want, groupErr.status)
}

func TestBlockedServiceGroupRestoreSnapshot(t *testing.T) {
	filtering.InitModule()
	ctx := testutil.ContextWithTimeout(t, testTimeout)

	const mac = "00:e0:4c:43:42:ec"
	previous := &filtering.BlockedServices{
		Schedule: schedule.FullWeekly(),
		IDs:      []string{"facebook"},
	}
	cli := newGroupTestClient(t, "phone", mac, false, previous.IDs, previous.Schedule)
	clients := &clientsContainer{storage: newStorage(t, []*client.Persistent{cli})}

	manager, err := newBlockedServiceGroupManager(ctx, nil, clients)
	require.NoError(t, err)

	_, err = manager.add(ctx, blockedServiceGroupData{
		Name:            "Invalid MAC",
		Members:         []string{"not-a-mac"},
		BlockedServices: []string{"youtube"},
	})
	requireGroupErrorStatus(t, http.StatusBadRequest, err)

	_, err = manager.add(ctx, blockedServiceGroupData{
		Name:            "Invalid service",
		BlockedServices: []string{"not-a-service"},
	})
	requireGroupErrorStatus(t, http.StatusBadRequest, err)

	group, err := manager.add(ctx, blockedServiceGroupData{
		Name:            " Children ",
		Members:         []string{"00-E0-4C-43-42-EC", mac},
		BlockedServices: []string{"youtube", "youtube"},
	})
	require.NoError(t, err)
	require.Equal(t, []string{mac}, group.Members)
	require.Equal(t, []string{"youtube"}, group.BlockedServices)

	grouped, ok := clients.storage.Find(mac)
	require.True(t, ok)
	assert.True(t, grouped.UseOwnBlockedServices)
	assert.Equal(t, []string{"youtube"}, grouped.BlockedServices.IDs)
	assert.True(t, blockedPoliciesEqual(
		grouped.BlockedServices,
		&filtering.BlockedServices{Schedule: schedule.EmptyWeekly(), IDs: []string{"youtube"}},
	))

	_, err = manager.update(ctx, group.ID, blockedServiceGroupData{
		Name:            "Children",
		Members:         []string{mac},
		BlockedServices: []string{"tiktok"},
	})
	require.NoError(t, err)

	configGroups := manager.forConfig()
	require.Len(t, configGroups, 1)
	require.Len(t, configGroups[0].Members, 1)
	snapshot := configGroups[0].Members[0]
	assert.True(t, snapshot.PreviousUseGlobalBlockedServices)
	assert.True(t, blockedPoliciesEqual(previous, snapshot.PreviousBlockedServices))

	_, err = manager.update(ctx, group.ID, blockedServiceGroupData{
		Name:            "Children",
		Members:         nil,
		BlockedServices: []string{"tiktok"},
	})
	require.NoError(t, err)

	restored, ok := clients.storage.Find(mac)
	require.True(t, ok)
	assert.False(t, restored.UseOwnBlockedServices)
	assert.True(t, blockedPoliciesEqual(previous, restored.BlockedServices))
}

func TestBlockedServiceGroupConflictsAndClientGuard(t *testing.T) {
	filtering.InitModule()
	ctx := testutil.ContextWithTimeout(t, testTimeout)

	const mac = "00:e0:4c:43:42:ed"
	cli := newGroupTestClient(
		t,
		"tablet",
		mac,
		true,
		[]string{"facebook"},
		schedule.FullWeekly(),
	)
	clients := &clientsContainer{storage: newStorage(t, []*client.Persistent{cli})}
	manager, err := newBlockedServiceGroupManager(ctx, nil, clients)
	require.NoError(t, err)

	group, err := manager.add(ctx, blockedServiceGroupData{
		Name:            "Children",
		Members:         []string{mac},
		BlockedServices: []string{"youtube"},
	})
	require.NoError(t, err)

	_, err = manager.add(ctx, blockedServiceGroupData{
		Name:            "CHILDREN",
		BlockedServices: []string{"tiktok"},
	})
	requireGroupErrorStatus(t, http.StatusConflict, err)

	_, err = manager.add(ctx, blockedServiceGroupData{
		Name:            "Guests",
		Members:         []string{mac},
		BlockedServices: []string{"tiktok"},
	})
	requireGroupErrorStatus(t, http.StatusConflict, err)

	current, ok := clients.storage.Find(mac)
	require.True(t, ok)
	allowed := current.ShallowClone()
	allowed.Name = "tablet-renamed"
	require.NoError(t, manager.updateClient(ctx, current.Name, allowed))

	forbidden := allowed.ShallowClone()
	forbidden.BlockedServices.IDs = []string{"facebook"}
	err = manager.updateClient(ctx, allowed.Name, forbidden)
	requireGroupErrorStatus(t, http.StatusConflict, err)

	require.NoError(t, manager.delete(ctx, group.ID))
	restored, ok := clients.storage.Find(mac)
	require.True(t, ok)
	assert.True(t, restored.UseOwnBlockedServices)
	assert.True(t, blockedPoliciesEqual(
		restored.BlockedServices,
		&filtering.BlockedServices{
			Schedule: schedule.FullWeekly(),
			IDs:      []string{"facebook"},
		},
	))
}

func TestBlockedServiceGroupStartupAndClientDelete(t *testing.T) {
	filtering.InitModule()
	ctx := testutil.ContextWithTimeout(t, testTimeout)

	const mac = "00:e0:4c:43:42:ee"
	cli := newGroupTestClient(
		t,
		"console",
		mac,
		false,
		[]string{"facebook"},
		schedule.FullWeekly(),
	)
	clients := &clientsContainer{storage: newStorage(t, []*client.Persistent{cli})}
	manager, err := newBlockedServiceGroupManager(ctx, []*blockedServiceGroupConfig{{
		ID:              "persisted-group-id",
		Name:            "Children",
		BlockedServices: []string{"youtube"},
		Members: []*blockedServiceGroupMemberConfig{{
			MAC:                              mac,
			PreviousUseGlobalBlockedServices: true,
			PreviousBlockedServices: &filtering.BlockedServices{
				Schedule: schedule.FullWeekly(),
				IDs:      []string{"facebook"},
			},
		}},
	}}, clients)
	require.NoError(t, err)

	materialized, ok := clients.storage.Find(mac)
	require.True(t, ok)
	assert.True(t, materialized.UseOwnBlockedServices)
	assert.True(t, blockedPoliciesEqual(
		materialized.BlockedServices,
		&filtering.BlockedServices{
			Schedule: schedule.EmptyWeekly(),
			IDs:      []string{"youtube"},
		},
	))

	assert.True(t, manager.deleteClient(ctx, cli.Name))
	assert.Empty(t, manager.list()[0].Members)
	_, ok = clients.storage.Find(mac)
	assert.False(t, ok)
}

// BMC_CODE END
