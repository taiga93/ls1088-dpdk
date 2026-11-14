// BMC_CODE START
package home

import (
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"

	"github.com/AdguardTeam/AdGuardHome/internal/filtering"
	"github.com/AdguardTeam/AdGuardHome/internal/schedule"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type blockedServiceRecordedCommand struct {
	name string
	args []string
}

type blockedServiceTestRunner struct {
	failSet  string
	commands []blockedServiceRecordedCommand
}

func (r *blockedServiceTestRunner) Run(
	name string,
	args ...string,
) (output []byte, err error) {
	r.commands = append(r.commands, blockedServiceRecordedCommand{
		name: name,
		args: args,
	})

	if r.failSet != "" && strings.Contains(strings.Join(args, " "), r.failSet) {
		return []byte("test failure"), errors.New("test failure")
	}

	return nil, nil
}

func (r *blockedServiceTestRunner) joined() (commands []string) {
	commands = make([]string, len(r.commands))
	for i, cmd := range r.commands {
		commands[i] = cmd.name + " " + strings.Join(cmd.args, " ")
	}

	return commands
}

func TestBlockedServiceRuleManagerSync(t *testing.T) {
	mac := mustParseBlockedServiceMAC(t, "00:11:22:33:44:55")
	runner := &blockedServiceTestRunner{}
	manager := &blockedServiceRuleManager{runner: runner}

	manager.Sync(blockedServiceRulesSnapshot{
		global: &filtering.BlockedServices{
			Schedule: schedule.EmptyWeekly(),
			IDs:      []string{"youtube"},
		},
		ipsets: map[string]blockedServiceIPSetNames{
			"facebook": {
				v4: "agh_041_facebook_4",
				v6: "agh_041_facebook_6",
			},
			"youtube": {
				v4: "agh_133_youtube_4",
				v6: "agh_133_youtube_6",
			},
		},
		clients: []blockedServiceClientRules{{
			services: &filtering.BlockedServices{
				Schedule: schedule.EmptyWeekly(),
				IDs:      []string{"facebook"},
			},
			macs:   []net.HardwareAddr{mac},
			useOwn: true,
		}, {
			services: &filtering.BlockedServices{
				Schedule: schedule.EmptyWeekly(),
				IDs:      []string{"tiktok"},
			},
			macs:   []net.HardwareAddr{mustParseBlockedServiceMAC(t, "00:11:22:33:44:66")},
			useOwn: false,
		}},
	})

	commands := runner.joined()
	joined := strings.Join(commands, "\n")
	assert.Contains(t, joined,
		"iptables -w -A BMC_SVC4 -m mac --mac-source 00:11:22:33:44:55 "+
			"-p tcp -m set --match-set agh_041_facebook_4 dst -j REJECT --reject-with tcp-reset")
	assert.Contains(t, joined,
		"ip6tables -w -A BMC_SVC6 -m mac --mac-source 00:11:22:33:44:55 "+
			"-p udp -m set --match-set agh_041_facebook_6 dst -j DROP")
	assert.Contains(t, joined,
		"iptables -w -A BMC_SVC4 -m mac --mac-source 00:11:22:33:44:55 -j RETURN")
	assert.Contains(t, joined,
		"iptables -w -A BMC_SVC4 -p tcp -m set --match-set agh_133_youtube_4 dst "+
			"-j REJECT --reject-with tcp-reset")
	assert.NotContains(t, joined, "tiktok")

	clientRule := commandIndex(commands, "agh_041_facebook_4")
	clientReturn := commandIndex(commands, "00:11:22:33:44:55 -j RETURN")
	globalRule := commandIndex(commands, "agh_133_youtube_4")
	require.NotEqual(t, -1, clientRule)
	require.NotEqual(t, -1, clientReturn)
	require.NotEqual(t, -1, globalRule)
	assert.Less(t, clientRule, clientReturn)
	assert.Less(t, clientReturn, globalRule)
}

func TestBlockedServiceRuleManagerContinuesAfterRuleError(t *testing.T) {
	runner := &blockedServiceTestRunner{failSet: "agh_133_youtube_4"}
	manager := &blockedServiceRuleManager{runner: runner}

	manager.Sync(blockedServiceRulesSnapshot{
		global: &filtering.BlockedServices{
			Schedule: schedule.EmptyWeekly(),
			IDs:      []string{"youtube", "facebook"},
		},
		ipsets: map[string]blockedServiceIPSetNames{
			"facebook": {v4: "agh_041_facebook_4", v6: "agh_041_facebook_6"},
			"youtube":  {v4: "agh_133_youtube_4", v6: "agh_133_youtube_6"},
		},
	})

	assert.Contains(t, strings.Join(runner.joined(), "\n"), "agh_041_facebook_4")
}

func TestParseBlockedServiceIPSets(t *testing.T) {
	ipsets, err := parseBlockedServiceIPSets(`
# Facebook | id=facebook | group=social_network | converted=2 | skipped=0
facebook.com,fb.com/agh_041_facebook_4,agh_041_facebook_6

# YouTube | id=youtube | group=streaming | converted=2 | skipped=0
youtube.com,yt.be/agh_133_youtube_4,agh_133_youtube_6
`)
	require.NoError(t, err)
	assert.Equal(t, blockedServiceIPSetNames{
		v4: "agh_041_facebook_4",
		v6: "agh_041_facebook_6",
	}, ipsets["facebook"])
	assert.Equal(t, "agh_133_youtube_4", ipsets["youtube"].v4)
}

func TestBlockedServiceTimeMatches(t *testing.T) {
	weekly := &schedule.Weekly{}
	err := json.Unmarshal([]byte(`{
		"time_zone":"Local",
		"mon":{"start":3600000,"end":7200000}
	}`), weekly)
	require.NoError(t, err)

	matches, err := blockedServiceTimeMatches(weekly)
	require.NoError(t, err)
	joined := make([]string, len(matches))
	for i, match := range matches {
		joined[i] = strings.Join(match, " ")
	}

	all := strings.Join(joined, "\n")
	assert.Contains(t, all,
		"-m time --kerneltz --timestart 00:00:00 --timestop 00:59:59 --weekdays Mon")
	assert.Contains(t, all,
		"-m time --kerneltz --timestart 02:00:00 --timestop 23:59:59 --weekdays Mon")
	assert.NotContains(t, all, "01:00:00")
}

func mustParseBlockedServiceMAC(t *testing.T, value string) (mac net.HardwareAddr) {
	t.Helper()

	mac, err := net.ParseMAC(value)
	require.NoError(t, err)

	return mac
}

func commandIndex(commands []string, part string) (idx int) {
	for i, command := range commands {
		if strings.Contains(command, part) {
			return i
		}
	}

	return -1
}

// BMC_CODE END
