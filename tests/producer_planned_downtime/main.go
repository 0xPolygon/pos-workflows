package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Tests producer planned downtime by:
// 1. Scheduling downtime for a future time
// 2. Waiting for downtime window to start
// 3. Verifying blocks during downtime are NOT produced by the downed producer
// 4. Verifying blocks after downtime resume normal production
func main() {
	enclave = os.Getenv("ENCLAVE_NAME")
	if enclave == "" {
		panic("environment variable ENCLAVE_NAME is not set")
	}

	var err error

	borRPC, err = getBorRPC()
	if err != nil {
		panic(fmt.Sprintf("Failed to get Bor RPC endpoint: %v", err))
	}

	fmt.Printf("Bor RPC endpoint: %s\n", borRPC)

	if err = waitForBlock(minStartBlock, time.Second); err != nil {
		panic(fmt.Sprintf("Failed waiting for min start block %d: %v", minStartBlock, err))
	}
	fmt.Printf("Reached min start block %d\n", minStartBlock)

	heimdallREST, err = getHeimdallRest()
	if err != nil {
		panic(fmt.Sprintf("Failed to get Heimdall REST endpoint: %v", err))
	}

	fmt.Printf("Heimdall REST endpoint: %s\n", heimdallREST)

	producerAddress, err := getProducerAddress(1)
	if err != nil {
		panic(fmt.Sprintf("Failed to get producer address: %v", err))
	}

	fmt.Printf("Producer address: %s\n", producerAddress)
	currentUnixTimestamp := time.Now().Unix()
	startDowntime := currentUnixTimestamp + downtimeStartSecondsInFuture
	endDowntime := startDowntime + downtimeDurationSeconds

	startBlock, endBlock, err := estimateDowntimeRange(startDowntime, endDowntime, producerAddress)
	if err != nil {
		panic(fmt.Sprintf("Failed to estimate downtime range: %v", err))
	}

	fmt.Printf("Estimated downtime range: Start: %d, End: %d\n", startBlock, endBlock)

	if err := getSpans(); err != nil {
		panic(fmt.Sprintf("Failed to get spans: %v", err))
	}

	fmt.Printf("Fetched %d spans from Heimdall\n", len(spans))

	var span *spanInfo
	for i := 0; i < 256; i++ {
		span, err = getSpanForBlock(startBlock)
		if err != nil {
			panic(fmt.Sprintf("Failed to get span for start block %d: %v", startBlock, err))
		}

		if span != nil {
			break
		}

		fmt.Printf("Span for start block %d not found yet, retrying...\n", startBlock)

		time.Sleep(10 * time.Second)

		if err := getSpans(); err != nil {
			panic(fmt.Sprintf("Failed to refresh spans: %v", err))
		}
	}

	if span == nil {
		panic(fmt.Sprintf("No span found covering start block %d", startBlock))
	}

	fmt.Printf("Producer for start block %d: ValID=%d, Address=%s\n", startBlock, span.ProducerValID, span.ProducerAddress)

	if err := execSetProducerDowntime(startDowntime, endDowntime, span.ProducerValID, span.ProducerAddress); err != nil {
		panic(fmt.Sprintf("Failed to set producer planned downtime: %v", err))
	}

	fmt.Println("Successfully set producer planned downtime")

	currentBlock, err := getCurrentBorBlockNumber()
	if err != nil {
		panic(fmt.Sprintf("Failed to get current Bor block number: %v", err))
	}

	var startDowntimeBlock, endDowntimeBlock int64

	for i := 0; i < 5; i++ {
		startDowntimeBlock, endDowntimeBlock, err = getProducerDowntimeBlocks(span.ProducerValID)
		if err != nil {
			if strings.Contains(err.Error(), "no planned downtime found for producer id") {
				fmt.Println("Downtime blocks not yet available, retrying...")
				time.Sleep(1 * time.Second)
				continue
			}
			panic(fmt.Sprintf("Failed to get producer downtime blocks: %v", err))
		}

		if startDowntimeBlock < currentBlock {
			time.Sleep(1 * time.Second)
			continue
		}

		break
	}

	fmt.Printf("Producer downtime blocks from Heimdall: Start: %d, End: %d\n", startDowntimeBlock, endDowntimeBlock)

	if err := waitForBlock(startDowntimeBlock, time.Second); err != nil {
		panic(fmt.Sprintf("Failed to wait for start downtime block: %v", err))
	}

	fmt.Printf("Downtime started at block %d\n", startDowntimeBlock)

	if err := getSpans(); err != nil {
		panic(fmt.Sprintf("Failed to refresh spans: %v", err))
	}

	// Check block before downtime
	author, err := getBorBlockAuthor(startDowntimeBlock - 1)
	if err != nil {
		panic(fmt.Sprintf("Failed to get author for block %d: %v", startDowntimeBlock-1, err))
	}

	expectedAuthor, err := getExpectedBlockAuthor(startDowntimeBlock - 1)
	if err != nil {
		panic(fmt.Sprintf("Failed to get expected author for block %d: %v", startDowntimeBlock-1, err))
	}

	if !strings.EqualFold(author, expectedAuthor) {
		panic(fmt.Sprintf("Block %d author mismatch: got %s, expected %s", startDowntimeBlock-1, author, expectedAuthor))
	}

	// Check first downtime block
	author, err = getBorBlockAuthor(startDowntimeBlock)
	if err != nil {
		panic(fmt.Sprintf("Failed to get author for block %d: %v", startDowntimeBlock, err))
	}

	expectedAuthor, err = getExpectedBlockAuthor(startDowntimeBlock)
	if err != nil {
		panic(fmt.Sprintf("Failed to get expected author for block %d: %v", startDowntimeBlock, err))
	}

	if !strings.EqualFold(author, expectedAuthor) {
		panic(fmt.Sprintf("Block %d author mismatch: got %s, expected different author due to downtime, expected %s", startDowntimeBlock, author, expectedAuthor))
	}

	if strings.EqualFold(author, span.ProducerAddress) {
		panic(fmt.Sprintf("Block %d author should not be the downtime producer %s", startDowntimeBlock, span.ProducerAddress))
	}

	if err := waitForBlock(endDowntimeBlock, time.Second); err != nil {
		panic(fmt.Sprintf("Failed to wait for end downtime block: %v", err))
	}

	fmt.Printf("Downtime ended at block %d\n", endDowntimeBlock)

	if err := getSpans(); err != nil {
		panic(fmt.Sprintf("Failed to refresh spans: %v", err))
	}

	// Check last downtime block
	author, err = getBorBlockAuthor(endDowntimeBlock)
	if err != nil {
		panic(fmt.Sprintf("Failed to get author for block %d: %v", endDowntimeBlock, err))
	}

	expectedAuthor, err = getExpectedBlockAuthor(endDowntimeBlock)
	if err != nil {
		panic(fmt.Sprintf("Failed to get expected author for block %d: %v", endDowntimeBlock, err))
	}

	if !strings.EqualFold(author, expectedAuthor) {
		panic(fmt.Sprintf("Block %d author mismatch: got %s, expected different author due to downtime, expected %s", endDowntimeBlock, author, expectedAuthor))
	}

	if strings.EqualFold(author, span.ProducerAddress) {
		panic(fmt.Sprintf("Block %d author should not be the downtime producer %s", endDowntimeBlock, span.ProducerAddress))
	}

	if err := waitForBlock(endDowntimeBlock+1, time.Second); err != nil {
		panic(fmt.Sprintf("Failed to wait for block after downtime: %v", err))
	}

	if err := getSpans(); err != nil {
		panic(fmt.Sprintf("Failed to refresh spans: %v", err))
	}

	// Check block after downtime
	author, err = getBorBlockAuthor(endDowntimeBlock + 1)
	if err != nil {
		panic(fmt.Sprintf("Failed to get author for block %d: %v", endDowntimeBlock+1, err))
	}

	expectedAuthor, err = getExpectedBlockAuthor(endDowntimeBlock + 1)
	if err != nil {
		panic(fmt.Sprintf("Failed to get expected author for block %d: %v", endDowntimeBlock+1, err))
	}

	if !strings.EqualFold(author, expectedAuthor) {
		panic(fmt.Sprintf("Block %d author mismatch: got %s, expected %s", endDowntimeBlock+1, author, expectedAuthor))
	}

	fmt.Println("Producer planned downtime test completed successfully")
}

var endpointRegex = regexp.MustCompile(`([a-zA-Z0-9\.-]+:\d+)`)

func sanitizeEndpoint(raw string) (string, error) {
	// Remove ANSI escape sequences
	ansi := regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
	clean := ansi.ReplaceAllString(raw, "")
	lines := strings.Split(clean, "\n")
	var candidates []string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		// Strip protocol prefix if present
		l = strings.TrimPrefix(l, "http://")
		l = strings.TrimPrefix(l, "https://")
		matches := endpointRegex.FindAllString(l, -1)
		if len(matches) > 0 {
			candidates = append(candidates, matches...)
		}
	}
	if len(candidates) == 0 {
		// Fallback: search entire cleaned output
		m := endpointRegex.FindString(clean)
		if m == "" {
			return "", fmt.Errorf("no endpoint host:port found")
		}
		return m, nil
	}
	// Use last match (in case warnings precede the actual endpoint)
	return candidates[len(candidates)-1], nil
}

func getBorRPC() (string, error) {
	out, err := execCommand(kurtosisGetBorRpc)
	if err != nil {
		return "", err
	}
	ep, err := sanitizeEndpoint(out)
	if err != nil {
		return "", fmt.Errorf("unable to parse Bor RPC endpoint: %v; raw: %s", err, out)
	}
	return ep, nil
}

func getHeimdallRest() (string, error) {
	out, err := execCommand(kurtosisGetHeimdallRest)
	if err != nil {
		return "", err
	}
	ep, err := sanitizeEndpoint(out)
	if err != nil {
		return "", fmt.Errorf("unable to parse Heimdall REST endpoint: %v; raw: %s", err, out)
	}
	return ep, nil
}

func getExpectedBlockAuthor(blockNumber int64) (string, error) {
	span, err := getSpanForBlock(blockNumber)
	if err != nil {
		return "", fmt.Errorf("failed to get span for block %d: %v", blockNumber, err)
	}
	if span == nil {
		return "", fmt.Errorf("no span found covering block %d", blockNumber)
	}
	return span.ProducerAddress, nil
}

func getProducerDowntimeBlocks(producerID int64) (int64, int64, error) {
	if heimdallREST == "" {
		return 0, 0, fmt.Errorf("heimdallREST is empty")
	}

	base := heimdallREST
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}
	url := fmt.Sprintf("%s/bor/producers/planned-downtime/%d", base, producerID)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to create request: %w", err)
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to GET %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, 0, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, fmt.Errorf("failed to read response: %w", err)
	}

	var r struct {
		DowntimeRange struct {
			StartBlock string `json:"start_block"`
			EndBlock   string `json:"end_block"`
		} `json:"downtime_range"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error,omitempty"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return 0, 0, fmt.Errorf("failed to parse response: %v; body: %s", err, string(body))
	}
	if r.Error != nil && r.Error.Message != "" {
		return 0, 0, fmt.Errorf("heimdall error %d: %s", r.Error.Code, r.Error.Message)
	}
	if r.DowntimeRange.StartBlock == "" || r.DowntimeRange.EndBlock == "" {
		return 0, 0, fmt.Errorf("missing downtime_range in response: %s", string(body))
	}

	startBlock, err1 := strconv.ParseInt(r.DowntimeRange.StartBlock, 10, 64)
	endBlock, err2 := strconv.ParseInt(r.DowntimeRange.EndBlock, 10, 64)
	if err1 != nil || err2 != nil {
		return 0, 0, fmt.Errorf("failed to parse block numbers: startErr=%v endErr=%v", err1, err2)
	}

	return startBlock, endBlock, nil
}

func waitForBlock(targetBlock int64, pollInterval time.Duration) error {
	for {
		currentBlock, err := getCurrentBorBlockNumber()
		if err != nil {
			return fmt.Errorf("failed to get current Bor block number: %w", err)
		}

		if currentBlock >= targetBlock {
			return nil
		}

		time.Sleep(pollInterval)
	}
}

func getBorBlockAuthor(blockNumber int64) (string, error) {
	if borRPC == "" {
		return "", fmt.Errorf("borRPC is empty")
	}

	base := borRPC
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}

	// Use Polygon Bor RPC method bor_getAuthor
	payload := fmt.Sprintf(`{"jsonrpc":"2.0","method":"bor_getAuthor","params":["0x%x"],"id":1}`, blockNumber)
	req, err := http.NewRequest("POST", base, strings.NewReader(payload))
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to POST to Bor RPC: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("unexpected status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	var rpcResp struct {
		Result string `json:"result"`
		Error  struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return "", fmt.Errorf("failed to parse bor_getAuthor response: %v", err)
	}
	if rpcResp.Error.Message != "" {
		return "", fmt.Errorf("bor_getAuthor error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}
	if rpcResp.Result == "" {
		return "", fmt.Errorf("empty author in response")
	}

	return rpcResp.Result, nil
}

func getCurrentBorBlockNumber() (int64, error) {
	if borRPC == "" {
		return 0, fmt.Errorf("borRPC is empty")
	}

	base := borRPC
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}

	payload := `{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false],"id":1}`
	req, err := http.NewRequest("POST", base, strings.NewReader(payload))
	if err != nil {
		return 0, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("failed to POST to Bor RPC: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("unexpected status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("failed to read response: %w", err)
	}

	var rpcResp struct {
		Result struct {
			Number string `json:"number"`
		} `json:"result"`
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &rpcResp); err != nil {
		return 0, fmt.Errorf("failed to parse block response: %v", err)
	}
	if rpcResp.Error != nil && rpcResp.Error.Message != "" {
		return 0, fmt.Errorf("RPC error %d: %s", rpcResp.Error.Code, rpcResp.Error.Message)
	}
	if rpcResp.Result.Number == "" || !strings.HasPrefix(strings.ToLower(rpcResp.Result.Number), "0x") {
		return 0, fmt.Errorf("missing hex number in response")
	}

	blockNumber, err := strconv.ParseInt(strings.TrimPrefix(rpcResp.Result.Number, "0x"), 16, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse block number: %v", err)
	}

	return blockNumber, nil
}

func execSetProducerDowntime(startDowntime, endDowntime, producerID int64, producerAddress string) error {
	cmdStr := fmt.Sprintf(heimdallProducerPlannedDowntimeCmd, producerAddress, startDowntime, endDowntime)
	output, err := execCommandInPod(cmdStr, fmt.Sprintf(heimdallValPod, producerID))
	if err != nil {
		return fmt.Errorf("failed to estimate downtime range: %v", err)
	}

	fmt.Println(output)

	return nil
}

func getSpanForBlock(blockNumber int64) (*spanInfo, error) {
	// Iterate spans in reverse order to find the most recent span covering the block
	for i := len(spans) - 1; i >= 0; i-- {
		span := spans[i]
		if blockNumber >= span.StartBlock && blockNumber <= span.EndBlock {
			return &span, nil
		}
	}
	return nil, nil
}

func getProducerAddress(producerID int64) (string, error) {
	out, err := execCommandInPod(heimdallGetProducerAddressCmd, fmt.Sprintf(heimdallValPod, producerID))
	if err != nil {
		return "", err
	}

	// Find JSON start (in case of leading lines like "0")
	startIdx := strings.Index(out, "{")
	if startIdx == -1 {
		return "", fmt.Errorf("no JSON found in output: %s", out)
	}
	jsonStr := out[startIdx:]

	type privValidator struct {
		Address string `json:"address"`
	}
	var pv privValidator
	if err := json.Unmarshal([]byte(jsonStr), &pv); err != nil {
		return "", fmt.Errorf("failed to parse JSON: %v; raw: %s", err, jsonStr)
	}
	if pv.Address == "" {
		return "", fmt.Errorf("address field empty in JSON: %s", jsonStr)
	}
	return pv.Address, nil
}

func estimateDowntimeRange(startDowntime, endDowntime int64, producerAddress string) (int64, int64, error) {
	cmdStr := heimdallProducerPlannedDowntimeCmd + " --calc-only"
	cmdStr = fmt.Sprintf(cmdStr, producerAddress, startDowntime, endDowntime)
	output, err := execCommandInPod(cmdStr, fmt.Sprintf(heimdallValPod, 1))
	if err != nil {
		return 0, 0, fmt.Errorf("failed to estimate downtime range: %v", err)
	}

	// Parse output to extract calculated start and end blocks
	// Example:
	// The command was successfully executed and returned '0'.
	// Average block time calculated: 1 seconds
	// Calculated start block: 14156
	// Calculated end block: 14216
	reStart := regexp.MustCompile(`(?mi)Calculated start block:\s*(\d+)`)
	reEnd := regexp.MustCompile(`(?mi)Calculated end block:\s*(\d+)`)

	startMatch := reStart.FindStringSubmatch(output)
	endMatch := reEnd.FindStringSubmatch(output)
	if len(startMatch) < 2 || len(endMatch) < 2 {
		return 0, 0, fmt.Errorf("failed to parse downtime range from output:\n%s", output)
	}

	startBlock, err1 := strconv.ParseInt(startMatch[1], 10, 64)
	endBlock, err2 := strconv.ParseInt(endMatch[1], 10, 64)
	if err1 != nil || err2 != nil {
		return 0, 0, fmt.Errorf("failed to parse block numbers: startErr=%v endErr=%v", err1, err2)
	}

	return startBlock, endBlock, nil
}

func getSpans() error {
	if heimdallREST == "" {
		return fmt.Errorf("heimdallREST is empty")
	}

	base := heimdallREST
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}

	client := &http.Client{Timeout: 10 * time.Second}

	spans = []spanInfo{}

	// Iterate over span IDs starting from 0
	for i := 0; ; i++ {
		url := fmt.Sprintf("%s/bor/spans/%d", base, i)
		resp, err := client.Get(url)
		if err != nil {
			// Stop iteration once we fail to fetch the next span
			if i == 0 {
				return fmt.Errorf("failed to GET %s: %w", url, err)
			}
			break
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			// Stop on first non-200 after having fetched some spans
			if i == 0 {
				return fmt.Errorf("unexpected status %d for %s", resp.StatusCode, url)
			}
			break
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			return fmt.Errorf("failed reading response from %s: %w", url, err)
		}

		var sr spanResponse
		if err := json.Unmarshal(body, &sr); err != nil {
			// If parsing fails for the first span, treat as error; otherwise stop iteration
			if i == 0 {
				return fmt.Errorf("failed to parse span %d: %v; body: %s", i, err, string(body))
			}
			break
		}

		startBlock, err1 := strconv.ParseInt(sr.Span.StartBlock, 10, 64)
		endBlock, err2 := strconv.ParseInt(sr.Span.EndBlock, 10, 64)
		if err1 != nil || err2 != nil {
			return fmt.Errorf("invalid block numbers in span %d: startErr=%v endErr=%v", i, err1, err2)
		}

		if len(sr.Span.SelectedProducers) > 1 {
			continue
		}

		valID := sr.Span.SelectedProducers[0].ValID
		signer := sr.Span.SelectedProducers[0].Signer

		parsedValID, err := strconv.ParseInt(valID, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid validator ID in span %d: %v", i, err)
		}
		spans = append(spans, spanInfo{
			ID:              sr.Span.ID,
			StartBlock:      startBlock,
			EndBlock:        endBlock,
			ProducerValID:   parsedValID,
			ProducerAddress: signer,
		})
	}

	return nil
}

func execCommand(cmdStr string) (string, error) {
	// Replace the GitHub Actions-style placeholder with the actual env value
	cmdStr = strings.ReplaceAll(cmdStr, "${{ env.ENCLAVE_NAME }}", enclave)

	// Execute the command via shell
	cmd := exec.Command("bash", "-c", cmdStr)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("command failed: %v, output: %s", err, strings.TrimSpace(string(out)))
	}

	return strings.TrimSpace(string(out)), nil
}

func execCommandInPod(cmdStr, podName string) (string, error) {
	// Full command to execute in pod
	fullCmdStr := fmt.Sprintf(kurtosisExecInPod, podName, cmdStr)

	// Replace the GitHub Actions-style placeholder with the actual env value
	fullCmdStr = strings.ReplaceAll(fullCmdStr, "${{ env.ENCLAVE_NAME }}", enclave)

	fmt.Println(fullCmdStr)
	// Execute the command via shell
	cmd := exec.Command("bash", "-c", fullCmdStr)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("command failed: %v, output: %s", err, strings.TrimSpace(string(out)))
	}

	return strings.TrimSpace(string(out)), nil
}

var enclave, heimdallREST, borRPC string

// Add a global slice to hold parsed spans
var spans []spanInfo

// Structs for parsed span data we store
type spanInfo struct {
	ID              string
	StartBlock      int64
	EndBlock        int64
	ProducerValID   int64
	ProducerAddress string
}

// Structs for decoding the Heimdall API response
type spanResponse struct {
	Span struct {
		ID                string `json:"id"`
		StartBlock        string `json:"start_block"`
		EndBlock          string `json:"end_block"`
		SelectedProducers []struct {
			ValID  string `json:"val_id"`
			Signer string `json:"signer"`
		} `json:"selected_producers"`
	} `json:"span"`
}

const (
	minStartBlock                = 128
	downtimeStartSecondsInFuture = 180 // 3 minutes
	downtimeDurationSeconds      = 180 // 3 minutes

	kurtosisExecInPod                  = "kurtosis service exec ${{ env.ENCLAVE_NAME }} %s -- \"%s\""
	kurtosisGetBorRpc                  = "kurtosis port print ${{ env.ENCLAVE_NAME }} l2-el-1-bor-heimdall-v2-validator rpc"
	kurtosisGetHeimdallRest            = "kurtosis port print ${{ env.ENCLAVE_NAME }} l2-cl-1-heimdall-v2-bor-validator http"
	heimdallGetProducerAddressCmd      = "cat /etc/heimdall/config/priv_validator_key.json"
	heimdallProducerPlannedDowntimeCmd = "heimdalld tx bor producer-downtime --producer-address %s --start-timestamp-utc %d --end-timestamp-utc %d --home /etc/heimdall"

	heimdallValPod = "l2-cl-%d-heimdall-v2-bor-validator"
)
