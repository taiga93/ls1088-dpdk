// BMC_CODE START
package home

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/AdguardTeam/AdGuardHome/internal/aghhttp"
)

type blockedServiceGroupsResponse struct {
	Groups []*blockedServiceGroup `json:"groups"`
}

type blockedServiceGroupUpdateRequest struct {
	ID   string                  `json:"id"`
	Data blockedServiceGroupData `json:"data"`
}

type blockedServiceGroupDeleteRequest struct {
	ID string `json:"id"`
}

func writeBlockedServiceGroupError(w http.ResponseWriter, r *http.Request, err error) {
	groupErr := &blockedServiceGroupError{}
	if errors.As(err, &groupErr) {
		aghhttp.Error(r, w, groupErr.status, "%s", groupErr.message)

		return
	}

	aghhttp.Error(r, w, http.StatusInternalServerError, "%s", err)
}

func blockedServiceGroupHTTPStatus(err error, fallback int) int {
	groupErr := &blockedServiceGroupError{}
	if errors.As(err, &groupErr) {
		return groupErr.status
	}

	return fallback
}

func commitBlockedServiceGroupChange() {
	onConfigModified()
	syncBlockedServiceRules()
}

func (m *blockedServiceGroupManager) handleGet(w http.ResponseWriter, r *http.Request) {
	aghhttp.WriteJSONResponseOK(w, r, blockedServiceGroupsResponse{Groups: m.list()})
}

func (m *blockedServiceGroupManager) handleAdd(w http.ResponseWriter, r *http.Request) {
	req := blockedServiceGroupData{}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		aghhttp.Error(r, w, http.StatusBadRequest, "failed to process request body: %s", err)

		return
	}

	group, err := m.add(r.Context(), req)
	if err != nil {
		writeBlockedServiceGroupError(w, r, err)

		return
	}

	commitBlockedServiceGroupChange()
	aghhttp.WriteJSONResponseOK(w, r, group)
}

func (m *blockedServiceGroupManager) handleUpdate(w http.ResponseWriter, r *http.Request) {
	req := blockedServiceGroupUpdateRequest{}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		aghhttp.Error(r, w, http.StatusBadRequest, "failed to process request body: %s", err)

		return
	}

	group, err := m.update(r.Context(), req.ID, req.Data)
	if err != nil {
		writeBlockedServiceGroupError(w, r, err)

		return
	}

	commitBlockedServiceGroupChange()
	aghhttp.WriteJSONResponseOK(w, r, group)
}

func (m *blockedServiceGroupManager) handleDelete(w http.ResponseWriter, r *http.Request) {
	req := blockedServiceGroupDeleteRequest{}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		aghhttp.Error(r, w, http.StatusBadRequest, "failed to process request body: %s", err)

		return
	}

	err := m.delete(r.Context(), req.ID)
	if err != nil {
		writeBlockedServiceGroupError(w, r, err)

		return
	}

	commitBlockedServiceGroupChange()
	aghhttp.WriteJSONResponseOK(w, r, struct{}{})
}

func (m *blockedServiceGroupManager) registerWebHandlers() {
	httpRegister(http.MethodGet, "/control/client_groups", m.handleGet)
	httpRegister(http.MethodPost, "/control/client_groups/add", m.handleAdd)
	httpRegister(http.MethodPost, "/control/client_groups/update", m.handleUpdate)
	httpRegister(http.MethodPost, "/control/client_groups/delete", m.handleDelete)
}

// BMC_CODE END
