// BMC_CODE START
package home

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/AdguardTeam/AdGuardHome/internal/client"
	"github.com/AdguardTeam/AdGuardHome/internal/filtering"
	"github.com/AdguardTeam/AdGuardHome/internal/schedule"
	"github.com/AdguardTeam/golibs/log"
)

const (
	blockedServiceChain4 = "BMC_SVC4"
	blockedServiceChain6 = "BMC_SVC6"
	blockedServiceIPSets = "/etc/ipset.conf"
)

type blockedServiceCommandRunner interface {
	Run(name string, args ...string) (output []byte, err error)
}

type blockedServiceExecRunner struct{}

func (blockedServiceExecRunner) Run(name string, args ...string) (output []byte, err error) {
	switch name {
	case "iptables", "ip6tables":
	default:
		return nil, fmt.Errorf("unsupported firewall command %q", name)
	}

	// #nosec G204 -- name is restricted to the two commands above.
	cmd := exec.Command(name, args...)
	output, err = cmd.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("running %s: %w: %s", name, err, strings.TrimSpace(string(output)))
	}

	return output, nil
}

type blockedServiceClientRules struct {
	services *filtering.BlockedServices
	macs     []net.HardwareAddr
	useOwn   bool
}

type blockedServiceRulesSnapshot struct {
	global  *filtering.BlockedServices
	clients []blockedServiceClientRules
	ipsets  map[string]blockedServiceIPSetNames
}

type blockedServiceIPSetNames struct {
	v4 string
	v6 string
}

type blockedServiceRuleManager struct {
	runner blockedServiceCommandRunner
	mu     sync.Mutex
}

var blockedServiceRules = &blockedServiceRuleManager{
	runner: blockedServiceExecRunner{},
}

// syncBlockedServiceRules rebuilds the BMC-owned chains from current settings.
func syncBlockedServiceRules() {
	if Context.filters == nil || Context.clients.storage == nil {
		log.Debug("blocked services iptables: filtering or clients are not initialized")

		return
	}

	filterConf := &filtering.Config{}
	Context.filters.WriteDiskConfig(filterConf)

	ipsets, err := loadBlockedServiceIPSets(blockedServiceIPSets)
	if err != nil {
		log.Error("blocked services iptables: loading ipset config: %s", err)

		return
	}

	snapshot := blockedServiceRulesSnapshot{
		global: filterConf.BlockedServices.Clone(),
		ipsets: ipsets,
	}
	Context.clients.storage.RangeByName(func(cli *client.Persistent) (cont bool) {
		macs := make([]net.HardwareAddr, len(cli.MACs))
		for i, mac := range cli.MACs {
			macs[i] = slices.Clone(mac)
		}

		snapshot.clients = append(snapshot.clients, blockedServiceClientRules{
			services: cli.BlockedServices.Clone(),
			macs:     macs,
			useOwn:   cli.UseOwnBlockedServices,
		})

		return true
	})

	blockedServiceRules.Sync(snapshot)
}

func (m *blockedServiceRuleManager) Sync(snapshot blockedServiceRulesSnapshot) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.syncFamily("iptables", blockedServiceChain4, "_v4", snapshot)
	m.syncFamily("ip6tables", blockedServiceChain6, "_v6", snapshot)
}

func (m *blockedServiceRuleManager) syncFamily(
	binary string,
	chain string,
	setSuffix string,
	snapshot blockedServiceRulesSnapshot,
) {
	if !m.ensureChain(binary, chain) {
		return
	}

	if _, err := m.runner.Run(binary, "-w", "-F", chain); err != nil {
		log.Error("blocked services iptables: flushing %s: %s", chain, err)

		return
	}

	for _, cli := range snapshot.clients {
		if !cli.useOwn {
			continue
		}

		for _, mac := range cli.macs {
			if len(mac) != 6 {
				log.Error("blocked services iptables: unsupported MAC address %q", mac)

				continue
			}

			m.addServiceRules(
				binary,
				chain,
				setSuffix,
				mac.String(),
				cli.services,
				snapshot.ipsets,
			)
		}
	}

	for _, cli := range snapshot.clients {
		if !cli.useOwn {
			continue
		}

		if len(cli.macs) == 0 {
			log.Error("blocked services iptables: client with own services has no MAC address")

			continue
		}

		for _, mac := range cli.macs {
			if len(mac) != 6 {
				continue
			}

			m.runRule(binary, "-w", "-A", chain,
				"-m", "mac", "--mac-source", mac.String(), "-j", "RETURN")
		}
	}

	m.addServiceRules(binary, chain, setSuffix, "", snapshot.global, snapshot.ipsets)
}

func (m *blockedServiceRuleManager) ensureChain(binary, chain string) (ok bool) {
	if _, err := m.runner.Run(binary, "-w", "-L", chain); err != nil {
		if _, createErr := m.runner.Run(binary, "-w", "-N", chain); createErr != nil {
			log.Error("blocked services iptables: creating %s: %s", chain, createErr)

			return false
		}
	}

	if _, err := m.runner.Run(binary, "-w", "-C", "FORWARD", "-j", chain); err != nil {
		if _, insertErr := m.runner.Run(
			binary,
			"-w", "-I", "FORWARD", "1", "-j", chain,
		); insertErr != nil {
			log.Error("blocked services iptables: hooking %s: %s", chain, insertErr)

			return false
		}
	}

	return true
}

func (m *blockedServiceRuleManager) addServiceRules(
	binary string,
	chain string,
	setSuffix string,
	mac string,
	services *filtering.BlockedServices,
	ipsets map[string]blockedServiceIPSetNames,
) {
	if services == nil || len(services.IDs) == 0 {
		return
	}

	matches, err := blockedServiceTimeMatches(services.Schedule)
	if err != nil {
		log.Error("blocked services iptables: preparing schedule: %s", err)

		return
	}

	for _, serviceID := range services.IDs {
		setName, ok := blockedServiceIPSetName(ipsets, serviceID, setSuffix)
		if !ok {
			log.Error("blocked services iptables: no %s ipset for service %q", setSuffix, serviceID)

			continue
		}

		for _, timeMatch := range matches {
			base := []string{"-w", "-A", chain}
			if mac != "" {
				base = append(base, "-m", "mac", "--mac-source", mac)
			}

			base = append(base, "-p", "tcp", "-m", "set", "--match-set", setName, "dst")
			tcpRule := append(slices.Clone(base), timeMatch...)
			tcpRule = append(tcpRule, "-j", "REJECT", "--reject-with", "tcp-reset")
			m.runRule(binary, tcpRule...)

			udpRule := slices.Clone(base)
			udpRule[findProtocolIndex(udpRule)] = "udp"
			udpRule = append(udpRule, timeMatch...)
			udpRule = append(udpRule, "-j", "DROP")
			m.runRule(binary, udpRule...)
		}
	}
}

func loadBlockedServiceIPSets(path string) (ipsets map[string]blockedServiceIPSetNames, err error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	return parseBlockedServiceIPSets(string(data))
}

func parseBlockedServiceIPSets(data string) (ipsets map[string]blockedServiceIPSetNames, err error) {
	ipsets = make(map[string]blockedServiceIPSetNames)
	pendingID := ""

	scanner := bufio.NewScanner(strings.NewReader(data))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "#") {
			if id := blockedServiceIDFromComment(line); id != "" {
				pendingID = id
			}

			continue
		}
		if line == "" || pendingID == "" {
			continue
		}

		_, names, ok := strings.Cut(line, "/")
		if !ok {
			pendingID = ""

			continue
		}

		setNames := strings.Split(names, ",")
		if len(setNames) < 2 {
			return nil, fmt.Errorf("service %q: expected IPv4 and IPv6 ipset names", pendingID)
		}

		ipsets[pendingID] = blockedServiceIPSetNames{
			v4: strings.TrimSpace(setNames[0]),
			v6: strings.TrimSpace(setNames[1]),
		}
		pendingID = ""
	}
	if err = scanner.Err(); err != nil {
		return nil, err
	}

	return ipsets, nil
}

func blockedServiceIDFromComment(line string) (id string) {
	const marker = "| id="

	_, tail, ok := strings.Cut(line, marker)
	if !ok {
		return ""
	}

	id, _, _ = strings.Cut(tail, " |")

	return strings.TrimSpace(id)
}

func blockedServiceIPSetName(
	ipsets map[string]blockedServiceIPSetNames,
	serviceID string,
	setSuffix string,
) (name string, ok bool) {
	names, ok := ipsets[serviceID]
	if !ok {
		return "", false
	}

	switch setSuffix {
	case "_v4":
		return names.v4, names.v4 != ""
	case "_v6":
		return names.v6, names.v6 != ""
	default:
		return "", false
	}
}

func findProtocolIndex(args []string) (idx int) {
	for i, arg := range args {
		if arg == "-p" && i+1 < len(args) {
			return i + 1
		}
	}

	panic("blocked services iptables: protocol argument is missing")
}

func (m *blockedServiceRuleManager) runRule(binary string, args ...string) {
	if _, err := m.runner.Run(binary, args...); err != nil {
		log.Error("blocked services iptables: adding rule: %s", err)
	}
}

func blockedServiceTimeMatches(weekly *schedule.Weekly) (matches [][]string, err error) {
	if weekly == nil {
		return [][]string{nil}, nil
	}

	allEmpty := true
	for day := time.Sunday; day <= time.Saturday; day++ {
		_, _, ok := weekly.Range(day)
		allEmpty = allEmpty && !ok
	}
	if allEmpty {
		return [][]string{nil}, nil
	}

	kernelTZ := false
	switch tz := weekly.TimeZone(); tz {
	case "UTC":
	case "Local":
		kernelTZ = true
	default:
		return nil, fmt.Errorf("unsupported time zone %q; only UTC and Local are supported", tz)
	}

	for day := time.Sunday; day <= time.Saturday; day++ {
		start, end, inactive := weekly.Range(day)
		if !inactive {
			matches = append(matches, blockedServiceTimeMatch(day, 0, 24*time.Hour, kernelTZ))

			continue
		}

		if start > 0 {
			matches = append(matches, blockedServiceTimeMatch(day, 0, start, kernelTZ))
		}
		if end < 24*time.Hour {
			matches = append(matches, blockedServiceTimeMatch(day, end, 24*time.Hour, kernelTZ))
		}
	}

	return matches, nil
}

func blockedServiceTimeMatch(
	day time.Weekday,
	start time.Duration,
	end time.Duration,
	kernelTZ bool,
) (args []string) {
	args = []string{"-m", "time"}
	if kernelTZ {
		args = append(args, "--kerneltz")
	}

	if start != 0 || end != 24*time.Hour {
		args = append(args,
			"--timestart", blockedServiceClock(start),
			"--timestop", blockedServiceClock(end-time.Second),
		)
	}

	return append(args, "--weekdays", blockedServiceWeekday(day))
}

func blockedServiceClock(d time.Duration) (clock string) {
	totalSeconds := int64(d / time.Second)
	hours := totalSeconds / 3600
	minutes := totalSeconds % 3600 / 60
	seconds := totalSeconds % 60

	return fmt.Sprintf("%02d:%02d:%02d", hours, minutes, seconds)
}

func blockedServiceWeekday(day time.Weekday) (name string) {
	return [...]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}[day]
}

// BMC_CODE END
