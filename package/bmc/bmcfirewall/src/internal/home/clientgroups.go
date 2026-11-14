// BMC_CODE START
package home

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync"

	"github.com/AdguardTeam/AdGuardHome/internal/client"
	"github.com/AdguardTeam/AdGuardHome/internal/filtering"
	"github.com/AdguardTeam/AdGuardHome/internal/schedule"
)

// blockedServiceGroupMemberConfig is the private, persisted representation of
// a group member.  Previous policy fields are intentionally not exposed by the
// HTTP API.
type blockedServiceGroupMemberConfig struct {
	PreviousBlockedServices          *filtering.BlockedServices `yaml:"previous_blocked_services"`
	MAC                              string                     `yaml:"mac"`
	PreviousUseGlobalBlockedServices bool                       `yaml:"previous_use_global_blocked_services"`
}

type blockedServiceGroupConfig struct {
	ID              string                             `yaml:"id"`
	Name            string                             `yaml:"name"`
	Members         []*blockedServiceGroupMemberConfig `yaml:"members"`
	BlockedServices []string                           `yaml:"blocked_services"`
}

type blockedServiceGroup struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Members         []string `json:"members"`
	BlockedServices []string `json:"blocked_services"`
}

type blockedServiceGroupData struct {
	Name            string   `json:"name"`
	Members         []string `json:"members"`
	BlockedServices []string `json:"blocked_services"`
}

type blockedServiceGroupError struct {
	message string
	status  int
}

func (e *blockedServiceGroupError) Error() string {
	return e.message
}

func newBlockedServiceGroupError(status int, format string, args ...any) error {
	return &blockedServiceGroupError{
		status:  status,
		message: fmt.Sprintf(format, args...),
	}
}

type blockedServiceGroupManager struct {
	clients *clientsContainer
	groups  []*blockedServiceGroupConfig
	mu      sync.Mutex
}

func newBlockedServiceGroupManager(
	ctx context.Context,
	confs []*blockedServiceGroupConfig,
	clients *clientsContainer,
) (m *blockedServiceGroupManager, err error) {
	m = &blockedServiceGroupManager{
		clients: clients,
		groups:  make([]*blockedServiceGroupConfig, 0, len(confs)),
	}

	names := map[string]struct{}{}
	ids := map[string]struct{}{}
	owners := map[string]string{}
	for i, conf := range confs {
		var normalized *blockedServiceGroupConfig
		normalized, err = m.normalizeConfig(conf)
		if err != nil {
			return nil, fmt.Errorf("blocked service group at index %d: %w", i, err)
		}

		if _, ok := ids[normalized.ID]; ok {
			return nil, fmt.Errorf("duplicate blocked service group id %q", normalized.ID)
		}
		ids[normalized.ID] = struct{}{}

		nameKey := strings.ToLower(normalized.Name)
		if _, ok := names[nameKey]; ok {
			return nil, fmt.Errorf("duplicate blocked service group name %q", normalized.Name)
		}
		names[nameKey] = struct{}{}

		for _, member := range normalized.Members {
			if owner, ok := owners[member.MAC]; ok {
				return nil, fmt.Errorf("mac %q belongs to groups %q and %q", member.MAC, owner, normalized.ID)
			}
			owners[member.MAC] = normalized.ID
		}

		m.groups = append(m.groups, normalized)
	}

	// Validate all persisted members before changing client storage, then
	// materialize all policies as one rollback-capable batch.
	changes := []blockedServiceClientChange{}
	clientOwners := map[string]string{}
	for _, group := range m.groups {
		for _, member := range group.Members {
			cli, ok := clients.storage.Find(member.MAC)
			if !ok {
				return nil, fmt.Errorf(
					"blocked service group %q: client with mac %q is not found",
					group.ID,
					member.MAC,
				)
			}
			if owner, ok := clientOwners[cli.Name]; ok {
				return nil, fmt.Errorf(
					"client %q belongs to groups %q and %q",
					cli.Name,
					owner,
					group.ID,
				)
			}
			clientOwners[cli.Name] = group.ID

			next := cli.ShallowClone()
			setGroupPolicy(next, group.BlockedServices)
			changes = append(changes, blockedServiceClientChange{before: cli, after: next})
		}
	}
	if err = m.applyChanges(ctx, changes); err != nil {
		return nil, fmt.Errorf("materializing blocked service groups: %w", err)
	}

	return m, nil
}

func normalizeGroupName(name string) (normalized string, err error) {
	normalized = strings.TrimSpace(name)
	if normalized == "" {
		return "", newBlockedServiceGroupError(http.StatusBadRequest, "group name must be non-empty")
	}

	return normalized, nil
}

func normalizeGroupMAC(raw string) (normalized string, err error) {
	mac, err := net.ParseMAC(strings.TrimSpace(raw))
	if err != nil || len(mac) != 6 {
		return "", newBlockedServiceGroupError(http.StatusBadRequest, "invalid mac address %q", raw)
	}

	return strings.ToLower(mac.String()), nil
}

func normalizeGroupServices(ids []string) (normalized []string, err error) {
	normalized = make([]string, 0, len(ids))
	seen := map[string]struct{}{}
	for _, raw := range ids {
		id := strings.ToLower(strings.TrimSpace(raw))
		if id == "" {
			return nil, newBlockedServiceGroupError(http.StatusBadRequest, "blocked service id must be non-empty")
		}
		if _, ok := seen[id]; ok {
			continue
		}

		seen[id] = struct{}{}
		normalized = append(normalized, id)
	}

	services := &filtering.BlockedServices{
		Schedule: schedule.EmptyWeekly(),
		IDs:      normalized,
	}
	if err = services.Validate(); err != nil {
		return nil, newBlockedServiceGroupError(http.StatusBadRequest, "%s", err)
	}

	return normalized, nil
}

func normalizeGroupMembers(members []string) (normalized []string, err error) {
	normalized = make([]string, 0, len(members))
	seen := map[string]struct{}{}
	for _, raw := range members {
		var mac string
		mac, err = normalizeGroupMAC(raw)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[mac]; ok {
			continue
		}

		seen[mac] = struct{}{}
		normalized = append(normalized, mac)
	}

	return normalized, nil
}

func cloneBlockedPolicy(policy *filtering.BlockedServices) *filtering.BlockedServices {
	if policy == nil {
		return &filtering.BlockedServices{Schedule: schedule.EmptyWeekly()}
	}

	clone := policy.Clone()
	if clone.Schedule == nil {
		clone.Schedule = schedule.EmptyWeekly()
	}

	return clone
}

func cloneGroupMember(member *blockedServiceGroupMemberConfig) *blockedServiceGroupMemberConfig {
	return &blockedServiceGroupMemberConfig{
		MAC:                              member.MAC,
		PreviousUseGlobalBlockedServices: member.PreviousUseGlobalBlockedServices,
		PreviousBlockedServices:          cloneBlockedPolicy(member.PreviousBlockedServices),
	}
}

func cloneBlockedServiceGroupConfig(conf *blockedServiceGroupConfig) *blockedServiceGroupConfig {
	clone := &blockedServiceGroupConfig{
		ID:              conf.ID,
		Name:            conf.Name,
		BlockedServices: slices.Clone(conf.BlockedServices),
		Members:         make([]*blockedServiceGroupMemberConfig, 0, len(conf.Members)),
	}
	for _, member := range conf.Members {
		if member == nil {
			clone.Members = append(clone.Members, nil)
		} else {
			clone.Members = append(clone.Members, cloneGroupMember(member))
		}
	}

	return clone
}

func (m *blockedServiceGroupManager) normalizeConfig(
	conf *blockedServiceGroupConfig,
) (normalized *blockedServiceGroupConfig, err error) {
	if conf == nil {
		return nil, newBlockedServiceGroupError(http.StatusBadRequest, "group must not be null")
	}

	normalized = cloneBlockedServiceGroupConfig(conf)
	normalized.ID = strings.TrimSpace(normalized.ID)
	if normalized.ID == "" {
		return nil, newBlockedServiceGroupError(http.StatusBadRequest, "group id must be non-empty")
	}

	normalized.Name, err = normalizeGroupName(normalized.Name)
	if err != nil {
		return nil, err
	}
	normalized.BlockedServices, err = normalizeGroupServices(normalized.BlockedServices)
	if err != nil {
		return nil, err
	}

	seen := map[string]struct{}{}
	for _, member := range normalized.Members {
		if member == nil {
			return nil, newBlockedServiceGroupError(http.StatusBadRequest, "group member must not be null")
		}

		member.MAC, err = normalizeGroupMAC(member.MAC)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[member.MAC]; ok {
			return nil, newBlockedServiceGroupError(
				http.StatusBadRequest,
				"duplicate group member %q",
				member.MAC,
			)
		}
		seen[member.MAC] = struct{}{}

		member.PreviousBlockedServices = cloneBlockedPolicy(member.PreviousBlockedServices)
		if err = member.PreviousBlockedServices.Validate(); err != nil {
			return nil, newBlockedServiceGroupError(
				http.StatusBadRequest,
				"invalid snapshot for mac %q: %s",
				member.MAC,
				err,
			)
		}
	}

	return normalized, nil
}

func setGroupPolicy(cli *client.Persistent, services []string) {
	cli.UseOwnBlockedServices = true
	cli.BlockedServices = &filtering.BlockedServices{
		Schedule: schedule.EmptyWeekly(),
		IDs:      slices.Clone(services),
	}
}

func restoreMemberPolicy(cli *client.Persistent, member *blockedServiceGroupMemberConfig) {
	cli.UseOwnBlockedServices = !member.PreviousUseGlobalBlockedServices
	cli.BlockedServices = cloneBlockedPolicy(member.PreviousBlockedServices)
}

func (m *blockedServiceGroupManager) groupIndex(id string) int {
	for i, group := range m.groups {
		if group.ID == id {
			return i
		}
	}

	return -1
}

func (m *blockedServiceGroupManager) memberOwner(mac, excludedGroupID string) string {
	for _, group := range m.groups {
		if group.ID == excludedGroupID {
			continue
		}
		for _, member := range group.Members {
			if member.MAC == mac {
				return group.ID
			}
		}
	}

	return ""
}

func (m *blockedServiceGroupManager) validateNameAvailable(name, excludedGroupID string) error {
	for _, group := range m.groups {
		if group.ID != excludedGroupID && strings.EqualFold(group.Name, name) {
			return newBlockedServiceGroupError(
				http.StatusConflict,
				"group name %q already exists",
				name,
			)
		}
	}

	return nil
}

type blockedServiceClientChange struct {
	before *client.Persistent
	after  *client.Persistent
}

func (m *blockedServiceGroupManager) applyChanges(
	ctx context.Context,
	changes []blockedServiceClientChange,
) (err error) {
	applied := 0
	for i, change := range changes {
		err = m.clients.storage.Update(ctx, change.before.Name, change.after)
		if err == nil {
			applied++
			continue
		}

		for rollbackIdx := applied - 1; rollbackIdx >= 0; rollbackIdx-- {
			appliedChange := changes[rollbackIdx]
			_ = m.clients.storage.Update(
				ctx,
				appliedChange.after.Name,
				appliedChange.before,
			)
		}

		return fmt.Errorf("updating group member at index %d: %w", i, err)
	}

	return nil
}

func newBlockedServiceGroupID() (id string, err error) {
	var raw [16]byte
	_, err = rand.Read(raw[:])
	if err != nil {
		return "", fmt.Errorf("generating group id: %w", err)
	}

	return hex.EncodeToString(raw[:]), nil
}

func groupPublic(conf *blockedServiceGroupConfig) *blockedServiceGroup {
	group := &blockedServiceGroup{
		ID:              conf.ID,
		Name:            conf.Name,
		BlockedServices: slices.Clone(conf.BlockedServices),
		Members:         make([]string, 0, len(conf.Members)),
	}
	for _, member := range conf.Members {
		group.Members = append(group.Members, member.MAC)
	}

	return group
}

func (m *blockedServiceGroupManager) list() (groups []*blockedServiceGroup) {
	m.mu.Lock()
	defer m.mu.Unlock()

	groups = make([]*blockedServiceGroup, 0, len(m.groups))
	for _, group := range m.groups {
		groups = append(groups, groupPublic(group))
	}

	return groups
}

func (m *blockedServiceGroupManager) forConfig() (groups []*blockedServiceGroupConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()

	groups = make([]*blockedServiceGroupConfig, 0, len(m.groups))
	for _, group := range m.groups {
		groups = append(groups, cloneBlockedServiceGroupConfig(group))
	}

	return groups
}

func (m *blockedServiceGroupManager) normalizeData(
	data blockedServiceGroupData,
) (name string, members, services []string, err error) {
	name, err = normalizeGroupName(data.Name)
	if err != nil {
		return "", nil, nil, err
	}
	members, err = normalizeGroupMembers(data.Members)
	if err != nil {
		return "", nil, nil, err
	}
	services, err = normalizeGroupServices(data.BlockedServices)
	if err != nil {
		return "", nil, nil, err
	}

	return name, members, services, nil
}

func (m *blockedServiceGroupManager) add(
	ctx context.Context,
	data blockedServiceGroupData,
) (public *blockedServiceGroup, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	name, members, services, err := m.normalizeData(data)
	if err != nil {
		return nil, err
	}
	if err = m.validateNameAvailable(name, ""); err != nil {
		return nil, err
	}

	id, err := newBlockedServiceGroupID()
	if err != nil {
		return nil, err
	}
	for m.groupIndex(id) >= 0 {
		id, err = newBlockedServiceGroupID()
		if err != nil {
			return nil, err
		}
	}

	group := &blockedServiceGroupConfig{
		ID:              id,
		Name:            name,
		BlockedServices: services,
		Members:         make([]*blockedServiceGroupMemberConfig, 0, len(members)),
	}
	changes := make([]blockedServiceClientChange, 0, len(members))
	memberClients := map[string]struct{}{}
	for _, mac := range members {
		cli, ok := m.clients.storage.Find(mac)
		if !ok {
			return nil, newBlockedServiceGroupError(
				http.StatusNotFound,
				"client with mac %q is not found",
				mac,
			)
		}
		if _, duplicate := memberClients[cli.Name]; duplicate {
			return nil, newBlockedServiceGroupError(
				http.StatusConflict,
				"client %q is listed more than once",
				cli.Name,
			)
		}
		memberClients[cli.Name] = struct{}{}

		if owner := m.groupForClient(cli); owner != nil {
			return nil, newBlockedServiceGroupError(
				http.StatusConflict,
				"mac %q already belongs to group %q",
				mac,
				owner.ID,
			)
		}

		group.Members = append(group.Members, &blockedServiceGroupMemberConfig{
			MAC:                              mac,
			PreviousUseGlobalBlockedServices: !cli.UseOwnBlockedServices,
			PreviousBlockedServices:          cloneBlockedPolicy(cli.BlockedServices),
		})
		next := cli.ShallowClone()
		setGroupPolicy(next, services)
		changes = append(changes, blockedServiceClientChange{before: cli, after: next})
	}

	if err = m.applyChanges(ctx, changes); err != nil {
		return nil, err
	}
	m.groups = append(m.groups, group)

	return groupPublic(group), nil
}

func (m *blockedServiceGroupManager) update(
	ctx context.Context,
	id string,
	data blockedServiceGroupData,
) (public *blockedServiceGroup, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	id = strings.TrimSpace(id)
	if id == "" {
		return nil, newBlockedServiceGroupError(http.StatusBadRequest, "group id must be non-empty")
	}

	idx := m.groupIndex(id)
	if idx < 0 {
		return nil, newBlockedServiceGroupError(http.StatusNotFound, "group %q is not found", id)
	}

	name, members, services, err := m.normalizeData(data)
	if err != nil {
		return nil, err
	}
	if err = m.validateNameAvailable(name, id); err != nil {
		return nil, err
	}

	current := m.groups[idx]
	oldMembers := make(map[string]*blockedServiceGroupMemberConfig, len(current.Members))
	for _, member := range current.Members {
		oldMembers[member.MAC] = member
	}

	nextGroup := &blockedServiceGroupConfig{
		ID:              id,
		Name:            name,
		BlockedServices: services,
		Members:         make([]*blockedServiceGroupMemberConfig, 0, len(members)),
	}
	changes := make([]blockedServiceClientChange, 0, len(current.Members)+len(members))
	retained := map[string]struct{}{}
	memberClients := map[string]struct{}{}
	for _, mac := range members {
		cli, ok := m.clients.storage.Find(mac)
		if !ok {
			return nil, newBlockedServiceGroupError(
				http.StatusNotFound,
				"client with mac %q is not found",
				mac,
			)
		}
		if _, duplicate := memberClients[cli.Name]; duplicate {
			return nil, newBlockedServiceGroupError(
				http.StatusConflict,
				"client %q is listed more than once",
				cli.Name,
			)
		}
		memberClients[cli.Name] = struct{}{}

		if owner := m.groupForClient(cli); owner != nil && owner.ID != id {
			return nil, newBlockedServiceGroupError(
				http.StatusConflict,
				"mac %q already belongs to group %q",
				mac,
				owner.ID,
			)
		}

		member, existed := oldMembers[mac]
		if existed {
			member = cloneGroupMember(member)
			retained[mac] = struct{}{}
		} else {
			member = &blockedServiceGroupMemberConfig{
				MAC:                              mac,
				PreviousUseGlobalBlockedServices: !cli.UseOwnBlockedServices,
				PreviousBlockedServices:          cloneBlockedPolicy(cli.BlockedServices),
			}
		}
		nextGroup.Members = append(nextGroup.Members, member)

		next := cli.ShallowClone()
		setGroupPolicy(next, services)
		changes = append(changes, blockedServiceClientChange{before: cli, after: next})
	}

	for _, member := range current.Members {
		if _, ok := retained[member.MAC]; ok {
			continue
		}

		cli, ok := m.clients.storage.Find(member.MAC)
		if !ok {
			return nil, newBlockedServiceGroupError(
				http.StatusNotFound,
				"client with mac %q is not found",
				member.MAC,
			)
		}

		next := cli.ShallowClone()
		restoreMemberPolicy(next, member)
		changes = append(changes, blockedServiceClientChange{before: cli, after: next})
	}

	if err = m.applyChanges(ctx, changes); err != nil {
		return nil, err
	}
	m.groups[idx] = nextGroup

	return groupPublic(nextGroup), nil
}

func (m *blockedServiceGroupManager) delete(ctx context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	id = strings.TrimSpace(id)
	if id == "" {
		return newBlockedServiceGroupError(http.StatusBadRequest, "group id must be non-empty")
	}

	idx := m.groupIndex(id)
	if idx < 0 {
		return newBlockedServiceGroupError(http.StatusNotFound, "group %q is not found", id)
	}

	group := m.groups[idx]
	changes := make([]blockedServiceClientChange, 0, len(group.Members))
	for _, member := range group.Members {
		cli, ok := m.clients.storage.Find(member.MAC)
		if !ok {
			return newBlockedServiceGroupError(
				http.StatusNotFound,
				"client with mac %q is not found",
				member.MAC,
			)
		}

		next := cli.ShallowClone()
		restoreMemberPolicy(next, member)
		changes = append(changes, blockedServiceClientChange{before: cli, after: next})
	}

	if err := m.applyChanges(ctx, changes); err != nil {
		return err
	}
	m.groups = slices.Delete(m.groups, idx, idx+1)

	return nil
}

func blockedPoliciesEqual(a, b *filtering.BlockedServices) bool {
	a = cloneBlockedPolicy(a)
	b = cloneBlockedPolicy(b)

	aIDs := slices.Clone(a.IDs)
	bIDs := slices.Clone(b.IDs)
	slices.Sort(aIDs)
	slices.Sort(bIDs)
	if !slices.Equal(aIDs, bIDs) {
		return false
	}

	aSchedule, aErr := json.Marshal(a.Schedule)
	bSchedule, bErr := json.Marshal(b.Schedule)

	return aErr == nil && bErr == nil && bytes.Equal(aSchedule, bSchedule)
}

func clientMACsEqual(a, b []net.HardwareAddr) bool {
	return slices.EqualFunc(a, b, func(aMAC, bMAC net.HardwareAddr) bool {
		return bytes.Equal(aMAC, bMAC)
	})
}

func (m *blockedServiceGroupManager) groupForClient(
	cli *client.Persistent,
) (group *blockedServiceGroupConfig) {
	for _, mac := range cli.MACs {
		normalized := strings.ToLower(mac.String())
		if owner := m.memberOwner(normalized, ""); owner != "" {
			return m.groups[m.groupIndex(owner)]
		}
	}

	return nil
}

func (m *blockedServiceGroupManager) updateClient(
	ctx context.Context,
	oldName string,
	next *client.Persistent,
) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	current, ok := m.clients.storage.FindByName(oldName)
	if !ok {
		return fmt.Errorf("client %q is not found", oldName)
	}

	group := m.groupForClient(current)
	if group != nil {
		if !clientMACsEqual(next.MACs, current.MACs) ||
			next.UseOwnBlockedServices != current.UseOwnBlockedServices ||
			!blockedPoliciesEqual(next.BlockedServices, current.BlockedServices) {
			return newBlockedServiceGroupError(
				http.StatusConflict,
				"client %q belongs to group %q; mac and blocked-service policy cannot be changed",
				oldName,
				group.ID,
			)
		}
	}

	return m.clients.storage.Update(ctx, oldName, next)
}

func (m *blockedServiceGroupManager) deleteClient(ctx context.Context, name string) (ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()

	cli, ok := m.clients.storage.FindByName(name)
	if !ok {
		return false
	}

	macs := map[string]struct{}{}
	for _, mac := range cli.MACs {
		macs[strings.ToLower(mac.String())] = struct{}{}
	}

	if !m.clients.storage.RemoveByName(ctx, name) {
		return false
	}

	for _, group := range m.groups {
		group.Members = slices.DeleteFunc(group.Members, func(member *blockedServiceGroupMemberConfig) bool {
			_, remove := macs[member.MAC]

			return remove
		})
	}

	return true
}

// BMC_CODE END
