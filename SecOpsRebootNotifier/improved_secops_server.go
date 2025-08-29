package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	// Service and task names
	SECOPS_NOTIFIER_SERVICE = "SecOpsNotifierService"
	TASK_NAME               = "SecOpsNotifierTask"

	// Encryption related constants
	REBOOT_NOTIFIER_AES_KEY = "NUVN7O9BNMQTIGFY"
	REBOOT_NOTIFIER_AES_IV  = "HLBS4GQC32WSRCAH"
	ENCRYPTION_KEY          = "Dt7Vug2dg25M2BFHZYcHr8HTyDPkZ7sX89oTxfrc7mc"

	// Binary file names
	SECOPS_WINDOWS_PATCH_BINARY_FILE_NAME = "SecOpsPatchWindowsBinary.exe"
	SECOPS_LINUX_PATCH_BINARY_FILE_NAME   = "SecOpsPatchLinuxBinary"
	SECOPS_MAC_PATCH_BINARY_FILE_NAME     = "SecOpsPatchMacBinary"
	SECOPS_PATCH_BINARY_CONFIG_FILE_NAME  = "SecOpsPatchBinaryConfig.json"
	SECOPS_NOTIFIER_CONFIG_FILE_NAME      = "SecOpsNotifierConfig.json"

	// Reboot configuration options
	REBOOT_NOW      = "Force reboot after patch deployment"
	GRACEFUL_REBOOT = "Graceful reboot"
	SCHEDULE_REBOOT = "Schedule reboot"
	NO_REBOOT       = "No reboot"

	// Version information
	VERSION = "2.0.0"
)

var (
	// Global configuration variables
	SECOPS_NOTIFIER_CONFIG               SecOpsNotifierConfig
	SECOPS_NOTIFIER_FILE_PATH            string
	SECOPS_NOTIFIER_CONFIG_FILE_PATH     string
	SECOPS_PATCH_BINARY_FILE_PATH        string
	SECOPS_PATCH_BINARY_CONFIG_FILE_PATH string
	ACCESS_TOKEN                         string
	DEBUG                                bool

	// Process identifier to prevent multiple instances
	PROCESS_ID_FILE string

	// File mutex for atomic operations on config file
	configMutex sync.Mutex

	// Logger for centralized logging
	logger  *log.Logger
	logFile *os.File
)

// SecOpsNotifierConfig holds all configuration for the reboot notification system
type SecOpsNotifierConfig struct {
	BaseURL           string   `json:"base_url"`
	JumpHostBaseURL   string   `json:"jump_host_base_url"`
	TaskScheduled     bool     `json:"task_scheduled"`
	RebootConfig      string   `json:"reboot_config"`
	RebootNow         bool     `json:"reboot_now"`
	ScheduledTime     string   `json:"scheduled_time"`
	PatchRecordIDList []string `json:"patch_record_id_list"`
	Identifier        string   `json:"identifier"`
	CustomMessage     string   `json:"custom_message"`
	DelayCounter      int      `json:"delay_counter"`
	Asset             string   `json:"asset"`
	AssetType         string   `json:"asset_type"`
	LastUpdated       string   `json:"last_updated"` // Track when config was last updated
	Version           string   `json:"version"`      // Track config version
}

// CommandResult stores all the output and metadata from a command execution
type CommandResult struct {
	Command    string
	Stdout     string
	Stderr     string
	ReturnCode int
	Error      error
	Duration   time.Duration
}

func init() {
	// Set debug mode from environment
	DEBUG = false
	if os.Getenv("SECOPS_DEBUG") == "1" || os.Getenv("SECOPS_DEBUG") == "true" {
		DEBUG = true
	}
}

// Initialize the application, setting up paths and logging
func initializeApp() error {
	// Get secure path for files
	securePath, err := getSecurePath()
	if err != nil {
		return fmt.Errorf("failed to get secure path: %v", err)
	}

	// Setup logging
	LOG_FILE_PATH := filepath.Join(securePath, "secops_notifier.log")
	logFile, err = os.OpenFile(LOG_FILE_PATH, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		return fmt.Errorf("failed to open log file: %v", err)
	}

	logger = log.New(logFile, "", log.LstdFlags)
	log.SetOutput(logFile)

	// Set up process lock file
	PROCESS_ID_FILE = filepath.Join(securePath, "secops_notifier.pid")

	// Set up file paths based on OS
	if runtime.GOOS == "darwin" {
		SECOPS_NOTIFIER_CONFIG_FILE_PATH = filepath.Join(securePath, SECOPS_NOTIFIER_CONFIG_FILE_NAME)
		SECOPS_NOTIFIER_FILE_PATH = filepath.Join(securePath, "SecOpsRebootNotifier.app")
	} else if runtime.GOOS == "windows" {
		SECOPS_NOTIFIER_CONFIG_FILE_PATH = filepath.Join(securePath, SECOPS_NOTIFIER_CONFIG_FILE_NAME)
		SECOPS_NOTIFIER_FILE_PATH = filepath.Join(securePath, "SecOpsNotifier.exe")
	} else {
		SECOPS_NOTIFIER_CONFIG_FILE_PATH = filepath.Join(securePath, SECOPS_NOTIFIER_CONFIG_FILE_NAME)
		SECOPS_NOTIFIER_FILE_PATH = filepath.Join(securePath, "SecOpsNotifier")
	}

	if runtime.GOOS == "windows" {
		SECOPS_PATCH_BINARY_FILE_PATH = filepath.Join(securePath, SECOPS_WINDOWS_PATCH_BINARY_FILE_NAME)
	} else if runtime.GOOS == "linux" {
		SECOPS_PATCH_BINARY_FILE_PATH = filepath.Join(securePath, SECOPS_LINUX_PATCH_BINARY_FILE_NAME)
	} else if runtime.GOOS == "darwin" {
		SECOPS_PATCH_BINARY_FILE_PATH = filepath.Join(securePath, SECOPS_MAC_PATCH_BINARY_FILE_NAME)
	} else {
		return fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}
	SECOPS_PATCH_BINARY_CONFIG_FILE_PATH = filepath.Join(securePath, SECOPS_PATCH_BINARY_CONFIG_FILE_NAME)

	// Set appropriate permissions
	if runtime.GOOS != "windows" {
		// Ensure directory has proper permissions
		if err := os.Chmod(securePath, 0750); err != nil {
			logger.Printf("Warning: Could not set secure permissions on directory: %v", err)
		}

		// Ensure log file has proper permissions
		if err := os.Chmod(LOG_FILE_PATH, 0640); err != nil {
			logger.Printf("Warning: Could not set secure permissions on log file: %v", err)
		}
	}

	return nil
}

// getSecurePath returns a secure location for storing files based on OS
func getSecurePath() (string, error) {
	var baseDir string

	if runtime.GOOS == "windows" {
		baseDir = filepath.Join(os.Getenv("ProgramData"), "SecOpsNotifierService")
	} else if runtime.GOOS == "linux" {
		baseDir = "/usr/local/bin/SecOpsNotifierService"
	} else if runtime.GOOS == "darwin" {
		// Use a more secure location on macOS than /tmp
		baseDir = "/usr/local/bin/SecOpsNotifierService"
		// baseDir = "/Library/Application Support/SecOpsNotifierService"
		// Fallback to user library if we don't have permission for system library
		// if _, err := os.Stat(baseDir); os.IsPermission(err) {
		// 	homeDir, err := os.UserHomeDir()
		// 	if err != nil {
		// 		return "", err
		// 	}
		// 	baseDir = filepath.Join(homeDir, "Library/Application Support/SecOpsNotifierService")
		// }
	} else {
		return "", fmt.Errorf("unsupported OS: %s", runtime.GOOS)
	}

	// Create directory with secure permissions
	if err := os.MkdirAll(baseDir, 0750); err != nil {
		return "", err
	}

	return baseDir, nil
}

// Debug logging function that only outputs when DEBUG is true
func debugLog(v ...interface{}) {
	if DEBUG {
		if logger != nil {
			logger.Println(append([]interface{}{"[DEBUG]"}, v...)...)
		} else {
			log.Println(append([]interface{}{"[DEBUG]"}, v...)...)
		}
	}
}

// acquireProcessLock ensures only one instance of the application is running
func acquireProcessLock() (bool, error) {
	// Check if process ID file exists
	if _, err := os.Stat(PROCESS_ID_FILE); err == nil {
		// Read the PID from file
		pidBytes, err := os.ReadFile(PROCESS_ID_FILE)
		if err != nil {
			return false, fmt.Errorf("error reading PID file: %v", err)
		}

		pidStr := strings.TrimSpace(string(pidBytes))
		pid, err := parseInt(pidStr)
		if err != nil {
			// Invalid PID, we can overwrite
			debugLog("Invalid PID in file, acquiring lock")
		} else {
			// Check if process is still running
			running, err := isProcessRunning(pid)
			if err != nil {
				debugLog("Error checking if process is running:", err)
			} else if running {
				return false, fmt.Errorf("another instance is already running with PID %d", pid)
			}
			debugLog("Process with PID", pid, "is not running, acquiring lock")
		}
	}

	// Write our PID to the file
	pid := os.Getpid()
	if err := os.WriteFile(PROCESS_ID_FILE, []byte(fmt.Sprintf("%d", pid)), 0640); err != nil {
		return false, fmt.Errorf("error writing PID file: %v", err)
	}

	return true, nil
}

// releaseProcessLock removes the process lock file
func releaseProcessLock() error {
	if _, err := os.Stat(PROCESS_ID_FILE); err == nil {
		return os.Remove(PROCESS_ID_FILE)
	}
	return nil
}

// isProcessRunning checks if a process with the given PID is running
func isProcessRunning(pid int) (bool, error) {
	if runtime.GOOS == "windows" {
		// For Windows, use tasklist
		cmd := exec.Command("tasklist", "/fi", fmt.Sprintf("PID eq %d", pid), "/fo", "csv", "/nh")
		output, err := cmd.Output()
		if err != nil {
			return false, err
		}
		return strings.Contains(string(output), fmt.Sprintf(`"%d"`, pid)), nil
	} else {
		// For Unix-like systems
		process, err := os.FindProcess(pid)
		if err != nil {
			return false, err
		}

		// On Unix, FindProcess always succeeds, so we need to check if the process exists
		err = process.Signal(syscall.Signal(0))
		return err == nil, nil
	}
}

// parseInt safely parses a string to int
func parseInt(s string) (int, error) {
	var result int
	_, err := fmt.Sscanf(s, "%d", &result)
	return result, err
}

// saveConfigInternal saves the configuration without acquiring the lock
// This is used internally by loadConfig when the lock is already held
func saveConfigInternal() error {
	// Update timestamp
	SECOPS_NOTIFIER_CONFIG.LastUpdated = time.Now().Format(time.RFC3339)

	// Marshal with indentation for better readability
	data, err := json.MarshalIndent(SECOPS_NOTIFIER_CONFIG, "", "  ")
	if err != nil {
		return fmt.Errorf("error marshaling config: %v", err)
	}

	// Write to a temporary file first
	tmpFile := SECOPS_NOTIFIER_CONFIG_FILE_PATH + ".tmp"
	if err := os.WriteFile(tmpFile, data, 0640); err != nil {
		return fmt.Errorf("error writing temporary config file: %v", err)
	}

	// Rename for atomic update
	if err := os.Rename(tmpFile, SECOPS_NOTIFIER_CONFIG_FILE_PATH); err != nil {
		return fmt.Errorf("error renaming temporary config file: %v", err)
	}

	// Set proper permissions
	if runtime.GOOS != "windows" {
		if err := os.Chmod(SECOPS_NOTIFIER_CONFIG_FILE_PATH, 0640); err != nil {
			return fmt.Errorf("error setting config file permissions: %v", err)
		}
	}

	debugLog("Config saved successfully")
	return nil
}

// loadConfig loads the configuration file with proper locking
func loadConfig() error {
	configMutex.Lock()
	defer configMutex.Unlock()

	debugLog("Loading config from", SECOPS_NOTIFIER_CONFIG_FILE_PATH)

	if _, err := os.Stat(SECOPS_NOTIFIER_CONFIG_FILE_PATH); os.IsNotExist(err) {
		// Create a default config if it doesn't exist
		SECOPS_NOTIFIER_CONFIG = SecOpsNotifierConfig{
			CustomMessage: "Reboot required to complete important updates.",
			DelayCounter:  3,
			RebootConfig:  GRACEFUL_REBOOT,
			Version:       VERSION,
			LastUpdated:   time.Now().Format(time.RFC3339),
		}
		return saveConfigInternal() // Use internal version that doesn't lock
	}

	data, err := os.ReadFile(SECOPS_NOTIFIER_CONFIG_FILE_PATH)
	if err != nil {
		return fmt.Errorf("error reading config file: %v", err)
	}

	err = json.Unmarshal(data, &SECOPS_NOTIFIER_CONFIG)
	if err != nil {
		return fmt.Errorf("error parsing config file: %v", err)
	}

	// Update version if needed
	if SECOPS_NOTIFIER_CONFIG.Version != VERSION {
		SECOPS_NOTIFIER_CONFIG.Version = VERSION
		SECOPS_NOTIFIER_CONFIG.LastUpdated = time.Now().Format(time.RFC3339)
		return saveConfigInternal() // Use internal version that doesn't lock
	}

	return nil
}

// saveConfig saves the configuration file with proper locking
func saveConfig() error {
	configMutex.Lock()
	defer configMutex.Unlock()

	return saveConfigInternal()
}

// updateConfig updates specific fields in the config and saves it
func updateConfig(updates map[string]interface{}) error {
	configMutex.Lock()
	defer configMutex.Unlock()

	// Load current config in case it changed
	data, err := os.ReadFile(SECOPS_NOTIFIER_CONFIG_FILE_PATH)
	if err != nil {
		return fmt.Errorf("error reading config for update: %v", err)
	}

	var config SecOpsNotifierConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return fmt.Errorf("error parsing config for update: %v", err)
	}

	// Apply updates
	configData, err := json.Marshal(config)
	if err != nil {
		return fmt.Errorf("error marshaling config for update: %v", err)
	}

	var configMap map[string]interface{}
	if err := json.Unmarshal(configData, &configMap); err != nil {
		return fmt.Errorf("error converting config to map: %v", err)
	}

	// Apply updates
	for k, v := range updates {
		configMap[k] = v
	}

	// Add timestamp and version
	configMap["last_updated"] = time.Now().Format(time.RFC3339)
	configMap["version"] = VERSION

	// Convert back to SecOpsNotifierConfig
	updatedData, err := json.Marshal(configMap)
	if err != nil {
		return fmt.Errorf("error marshaling updated config: %v", err)
	}

	if err := json.Unmarshal(updatedData, &SECOPS_NOTIFIER_CONFIG); err != nil {
		return fmt.Errorf("error converting map back to config: %v", err)
	}

	// Save updated config
	return saveConfigInternal() // Use internal version that doesn't lock
}

// extendKey expands a key to the required length
func extendKey(key []byte, length int) []byte {
	extended := make([]byte, length)
	for i := 0; i < length; i++ {
		extended[i] = key[i%len(key)]
	}
	return extended
}

// decrypt decrypts an encrypted base64 string
func decrypt(encryptedB64 string, key string) (string, error) {
	encryptedBytes, err := base64.StdEncoding.DecodeString(encryptedB64)
	if err != nil {
		return "", fmt.Errorf("base64 decode error: %v", err)
	}
	keyBytes := []byte(key)
	extendedKey := extendKey(keyBytes, len(encryptedBytes))
	decrypted := make([]byte, len(encryptedBytes))
	for i := 0; i < len(encryptedBytes); i++ {
		decrypted[i] = encryptedBytes[i] ^ extendedKey[i]
	}
	return string(decrypted), nil
}

// executeCommandWithTimeout runs a command with the given timeout
func executeCommandWithTimeout(script string, arguments string, timeout time.Duration) CommandResult {
	debugLog("executeCommandWithTimeout", "script=", script, "args=", arguments, "timeout=", timeout)
	start := time.Now()
	result := CommandResult{Command: script}
	var cmd *exec.Cmd
	command := script
	currentDir, err := os.Getwd()
	if err != nil {
		result.Stderr = fmt.Sprintf("failed to get current directory: %v", err)
		return result
	}
	switch runtime.GOOS {
	case "windows":
		fullCommand := fmt.Sprintf("%s %s", command, arguments)
		cmd = exec.Command("powershell", "-Command", fullCommand)
	default:
		fullCommand := fmt.Sprintf("%s %s", command, arguments)
		cmd = exec.Command("bash", "-c", fullCommand)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd = exec.CommandContext(ctx, cmd.Path, cmd.Args[1:]...)
	cmd.Dir = currentDir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	result.Duration = time.Since(start)
	result.Stdout = stdout.String()
	result.Stderr = stderr.String()
	if cmd.ProcessState != nil {
		result.ReturnCode = cmd.ProcessState.ExitCode()
	}
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			result.Stderr = fmt.Sprintf("command timed out after %v", timeout)
		} else {
			result.Stderr = result.Stderr + "\n" + err.Error()
		}
	}
	debugLog("command finished", "stdoutLen=", len(result.Stdout), "stderrLen=", len(result.Stderr), "rc=", result.ReturnCode)
	return result
}

// stopAndRemoveService stops and removes the notification service
func stopAndRemoveService() {
	log.Println("Triggered the stop and remove service function")
	if runtime.GOOS == "windows" {
		stopCommand := fmt.Sprintf("Stop-Service -Name '%s' -Force", SECOPS_NOTIFIER_SERVICE)
		if err := runPowerShellCommand(stopCommand); err != nil {
			log.Printf("Error stopping service: %v", err)
			return
		}
		log.Printf("Service '%s' has been stopped and removed successfully.", SECOPS_NOTIFIER_SERVICE)
	}

	// Always clean up the process lock
	if err := releaseProcessLock(); err != nil {
		log.Printf("Error releasing process lock: %v", err)
	}
}

// deleteScheduledTask removes any scheduled reboot task
func deleteScheduledTask() error {
	debugLog("deleteScheduledTask start")
	if runtime.GOOS == "windows" {
		command := fmt.Sprintf(`$taskName = '%s'; if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }`, TASK_NAME)
		if err := runPowerShellCommand(command); err != nil {
			log.Printf("Error deleting scheduled task: %v", err)
			return err
		}
		log.Printf("Scheduled task '%s' has been deleted successfully.", TASK_NAME)
		return nil
	} else if runtime.GOOS == "linux" {
		scriptPath := "/usr/local/bin/SecOpsNotifierService/secops_notifier_task.sh"
		_ = exec.Command("pkill", "-f", scriptPath).Run()
		if err := os.Remove(scriptPath); err != nil {
			if !os.IsNotExist(err) {
				log.Printf("Error deleting task script '%s': %v", scriptPath, err)
				return err
			}
		} else {
			log.Printf("Deleted task script '%s' successfully.", scriptPath)
		}
	} else if runtime.GOOS == "darwin" {
		// Get secure script path
		securePath, err := getSecurePath()
		if err != nil {
			return err
		}
		scriptPath := filepath.Join(securePath, "secops_notifier_task.sh")

		// Kill any running instances
		_ = exec.Command("pkill", "-f", scriptPath).Run()

		// Remove the script
		if err := os.Remove(scriptPath); err != nil {
			if !os.IsNotExist(err) {
				log.Printf("Error deleting task script '%s': %v", scriptPath, err)
				return err
			}
		} else {
			log.Printf("Deleted task script '%s' successfully.", scriptPath)
		}
	}
	debugLog("deleteScheduledTask end")
	return nil
}

// scheduleTask creates a scheduled task for reboot notification
func scheduleTask(scheduledTime string) {
	debugLog("scheduleTask", "scheduledTime=", scheduledTime, "GOOS=", runtime.GOOS)

	// Always clean up existing tasks first
	deleteScheduledTask()

	if runtime.GOOS == "windows" {
		command := fmt.Sprintf(`$taskName='%s';$ScheduledTime='%s';$Action=New-ScheduledTaskAction -Execute '%s';$Settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable`, TASK_NAME, scheduledTime, SECOPS_NOTIFIER_FILE_PATH)
		if scheduledTime == "" {
			command += `;$Trigger=New-ScheduledTaskTrigger -Once -At (Get-Date);$Principal=New-ScheduledTaskPrincipal -GroupId "Users" -RunLevel Highest;Register-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -TaskName $taskName -Description 'SecOps Reboot Notifier';Start-ScheduledTask -TaskName $taskName`
		} else {
			command += `;$Trigger=New-ScheduledTaskTrigger -Once -At $ScheduledTime;$Principal=New-ScheduledTaskPrincipal -GroupId "Users" -RunLevel Highest;Register-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -TaskName $taskName -Description 'SecOps Reboot Notifier'`
		}
		if err := runPowerShellCommand(command); err != nil {
			log.Printf("Error creating task: %v", err)
			return
		}
		log.Printf("Task '%s' created.", TASK_NAME)
	} else if runtime.GOOS == "linux" {
		// Get secure script path
		securePath, err := getSecurePath()
		if err != nil {
			log.Printf("Error getting secure path: %v", err)
			return
		}
		scriptPath := filepath.Join(securePath, "secops_notifier_task.sh")

		reboot_custom_message := SECOPS_NOTIFIER_CONFIG.CustomMessage
		scriptContent := fmt.Sprintf(`#!/bin/bash
JSON_FILE="%s"
REBOOT_TIME="%s"
send_wall_message(){ echo "SecOps Solution - Reboot Required: %s. Your system is scheduled to reboot at $REBOOT_TIME." | wall; }
send_wall_message

# Use flock to prevent race conditions when updating JSON
update_json() {
    (
        flock -x 200
        sed -i 's/"reboot_now": *[^,}]+/"reboot_now": true/' $JSON_FILE
    ) 200>"%s.lock"
}

TARGET_TIMESTAMP=$(date -d "$REBOOT_TIME" +%%s 2>/dev/null)
CURRENT_TIME=$(date +%%s)
if [[ -z "$TARGET_TIMESTAMP" || $TARGET_TIMESTAMP -le $CURRENT_TIME ]]; then 
    update_json
else 
    sleep $((TARGET_TIMESTAMP-CURRENT_TIME))
    update_json
fi
`, SECOPS_NOTIFIER_CONFIG_FILE_PATH, scheduledTime, reboot_custom_message, SECOPS_NOTIFIER_CONFIG_FILE_PATH)

		// Write script with secure permissions
		if err := os.WriteFile(scriptPath, []byte(scriptContent), 0750); err != nil {
			log.Printf("Error creating task script: %v", err)
			return
		}

		cmd := exec.Command("bash", scriptPath)
		if err := cmd.Start(); err != nil {
			log.Printf("Error starting task script: %v", err)
			return
		}
		log.Printf("Scheduled task script '%s' created and executed.", scriptPath)
	} else if runtime.GOOS == "darwin" {
		// Get secure script path
		securePath, err := getSecurePath()
		if err != nil {
			log.Printf("Error getting secure path: %v", err)
			return
		}
		scriptPath := filepath.Join(securePath, "secops_notifier_task.sh")

		reboot_custom_message := SECOPS_NOTIFIER_CONFIG.CustomMessage
		// We embed the notifier app path so it can be opened at the target time
		appPath := SECOPS_NOTIFIER_FILE_PATH

		scriptContent := fmt.Sprintf(`#!/bin/bash
# Set up a lock file for atomic JSON operations
LOCK_FILE="%s.lock"
JSON_FILE="%s"
REBOOT_TIME="%s"
NOTIFIER_APP="%s"

# Create notification with the proper message
msg="SecOps Solution - Reboot Required: %s. Your system is scheduled to reboot at $REBOOT_TIME."
/usr/bin/osascript -e "display notification \"$msg\" with title \"SecOps Notifier\""

# Check if notifier is already running before launching
check_notifier_running() {
    pgrep -f "SecOpsRebootNotifier" > /dev/null
    return $?
}

# Function to set reboot_now true in JSON with file locking (mac sed syntax)
update_json() {
    (
        if flock -n 200; then
            /usr/bin/sed -i '' 's/"reboot_now": *[^,}][^,}]*/"reboot_now": true/' "$JSON_FILE"
            flock -u 200
        else
            echo "Could not acquire lock for $JSON_FILE" >&2
        fi
    ) 200>"$LOCK_FILE"
}

# Convert scheduled time to epoch (expects format: YYYY-MM-DD HH:MM:SS)
TARGET_TIMESTAMP=$(date -j -f "%%Y-%%m-%%d %%H:%%M:%%S" "$REBOOT_TIME" +%%s 2>/dev/null)
CURRENT_TIME=$(date +%%s)

if [ -z "$TARGET_TIMESTAMP" ] || [ $TARGET_TIMESTAMP -le $CURRENT_TIME ]; then
    # Time already passed or invalid -> act immediately
    update_json
    if [ -d "$NOTIFIER_APP" ] && ! check_notifier_running; then
        /usr/bin/open "$NOTIFIER_APP"
    fi
else
    # Sleep until the scheduled time, then update JSON and launch app
    SLEEP_FOR=$((TARGET_TIMESTAMP-CURRENT_TIME))
    sleep $SLEEP_FOR
    update_json
    if [ -d "$NOTIFIER_APP" ] && ! check_notifier_running; then
        /usr/bin/open "$NOTIFIER_APP"
        /usr/bin/osascript -e "display notification \"Launching reboot notifier...\" with title \"SecOps Notifier\""
    fi
fi
`, SECOPS_NOTIFIER_CONFIG_FILE_PATH, SECOPS_NOTIFIER_CONFIG_FILE_PATH, scheduledTime, appPath, reboot_custom_message)

		// Write script with secure permissions
		if err := os.WriteFile(scriptPath, []byte(scriptContent), 0750); err != nil {
			log.Printf("Error creating macOS task script: %v", err)
			return
		}

		cmd := exec.Command("bash", scriptPath)
		if err := cmd.Start(); err != nil {
			log.Printf("Error starting macOS task script: %v", err)
			return
		}
		log.Printf("Scheduled macOS task script '%s' created and executed in background.", scriptPath)
	}
	debugLog("scheduleTask exit")
}

// runPowerShellCommand executes a PowerShell command
func runPowerShellCommand(command string) error {
	cmd := exec.Command("powershell", "-Command", command)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("command failed: %v, output: %s", err, string(output))
	}
	return nil
}

// checkLinuxDistribution identifies the Linux package manager
func checkLinuxDistribution() string {
	CHECK_LINUX_DISTRO := `#!/bin/bash
if command -v apt &> /dev/null; then echo "This system uses APT."; elif command -v yum &> /dev/null; then echo "This system uses YUM."; elif command -v zypper &> /dev/null; then echo "This system uses Zypper."; else echo "Neither APT, YUM, nor Zypper is available on this system."; fi`
	result := executeCommandWithTimeout(CHECK_LINUX_DISTRO, "", 30*time.Second)
	if result.Error != nil {
		return ""
	}
	out := result.Stdout
	switch {
	case strings.Contains(out, "APT"):
		return "apt"
	case strings.Contains(out, "YUM"):
		return "yum"
	case strings.Contains(out, "Zypper"):
		return "zypper"
	default:
		return ""
	}
}

// scheduleRebootNowTask schedules an immediate reboot
func scheduleRebootNowTask(c *SecOpsNotifierConfig) {
	debugLog("scheduleRebootNowTask invoked", "GOOS=", runtime.GOOS, "RebootNow=", c.RebootNow)
	if runtime.GOOS == "windows" {
		command := fmt.Sprintf(`$Action=New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/F /R /T 120';$Trigger=New-ScheduledTaskTrigger -Once -At (Get-Date);$Settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable;$Principal=New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest;Register-ScheduledTask -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -TaskName '%s' -Description 'Reboot the machine with a 2-minute delay';Start-ScheduledTask -TaskName '%s'`, TASK_NAME, TASK_NAME)
		if err := runPowerShellCommand(command); err != nil {
			log.Printf("Error creating reboot task: %v", err)
			return
		}
		log.Printf("Task '%s' created for reboot.", TASK_NAME)
	} else if runtime.GOOS == "linux" {
		msg := c.CustomMessage
		command := fmt.Sprintf(`echo "System will reboot in next 2 minutes"; wall "SecOps Solution - Device Will Reboot Shortly: %s . Your system will reboot in next 2 minutes"; sleep 120; sudo reboot`, msg)
		if err := exec.Command("bash", "-c", command).Start(); err != nil {
			log.Printf("Error scheduling force reboot: %v", err)
			return
		}
		log.Println("Linux reboot scheduled in next 2 minutes.")
	} else if runtime.GOOS == "darwin" {
		// Get secure script path
		securePath, err := getSecurePath()
		if err != nil {
			log.Printf("Error getting secure path: %v", err)
			return
		}

		scriptPath := filepath.Join(securePath, "secops_mac_reboot_now.sh")
		msg := c.CustomMessage

		// Create the reboot script (commented portion preserved)
		script := fmt.Sprintf(`#!/bin/bash
set -e
MSG="SecOps Solution - Device Will Reboot Shortly: %s. Your system will reboot in 2 minutes."
/usr/bin/osascript -e "display notification \"$MSG\" with title \"SecOps Notifier\""
sleep 120
/usr/bin/osascript -e "display notification \"Rebooting now...\" with title \"SecOps Notifier\""

# The actual reboot command would be uncommented in production
# sudo /sbin/shutdown -r now
`, escapeAppleScriptString(msg))

		// Write script with secure permissions
		if err := os.WriteFile(scriptPath, []byte(script), 0750); err != nil {
			log.Printf("Error writing mac reboot script: %v", err)
			return
		}

		// Start the script
		if err := exec.Command("bash", scriptPath).Start(); err != nil {
			log.Printf("Error starting mac reboot script: %v", err)
			return
		}

		log.Println("macOS reboot scheduled in next 2 minutes.")
	}
}

// escapeAppleScriptString escapes quotes in strings for AppleScript
func escapeAppleScriptString(s string) string {
	return strings.ReplaceAll(s, `"`, `\"`)
}

// checkIfRebootRequired checks if system needs a reboot
func checkIfRebootRequired() (bool, error) {
	return true, nil
	debugLog("checkIfRebootRequired start", "GOOS=", runtime.GOOS)

	if runtime.GOOS == "windows" {
		CHECK := ` $progressPreference='SilentlyContinue'; $rebootPending=Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending'; $rebootRequired=Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired'; if($rebootPending -or $rebootRequired){Write-Output 'A restart is required.'} else {Write-Output 'No restart required.'}`
		cmd := exec.Command("powershell", "-Command", CHECK)
		output, err := cmd.CombinedOutput()
		if err != nil {
			return false, fmt.Errorf("error checking Windows reboot status: %v", err)
		}
		out := string(output)
		return strings.Contains(out, "A restart is required."), nil
	} else if runtime.GOOS == "linux" {
		packageManager := checkLinuxDistribution()
		if packageManager == "yum" {
			_ = executeCommandWithTimeout("sudo yum install -y yum-utils", "", 600*time.Second)
		}

		CHECK := `#!/bin/bash
if [ -f /var/run/reboot-required ] || [ -f /var/run/reboot-required.pkgs ]; then echo "System requires a reboot."; exit 0; fi
if command -v zypper &>/dev/null; then OUTPUT=$(zypper ps -sss); if echo "$OUTPUT" | grep -q '(deleted)'; then echo "System requires a reboot."; fi; fi
if command -v needs-restarting &>/dev/null; then if needs-restarting -r >/dev/null 2>&1; then echo "No reboot"; else echo "System requires a reboot."; fi; fi
echo "No reboot"`

		cmd := exec.Command("bash", "-c", CHECK)
		output, err := cmd.CombinedOutput()
		if err != nil {
			return false, fmt.Errorf("error checking Linux reboot status: %v", err)
		}
		return strings.Contains(string(output), "System requires a reboot"), nil
	} else if runtime.GOOS == "darwin" {
		// Check for pending macOS updates that require reboot
		// First check if SoftwareUpdate indicates pending restart
		cmd := exec.Command("bash", "-c", "softwareupdate -l | grep -i 'restart required'")
		output, _ := cmd.CombinedOutput()
		if strings.Contains(string(output), "restart required") {
			return true, nil
		}

		// Check our own flag file
		securePath, err := getSecurePath()
		if err != nil {
			return false, fmt.Errorf("error getting secure path: %v", err)
		}

		pendingRebootFile := filepath.Join(securePath, "pendingReboot.txt")
		if _, err := os.Stat(pendingRebootFile); err == nil {
			return true, nil
		}

		// Default to false if no indicators found
		return false, nil
	}

	return false, fmt.Errorf("unsupported OS")
}

// checkPatchTaskProcess checks if a patch task is currently running
func checkPatchTaskProcess() bool {
	debugLog("checkPatchTaskProcess start")

	// First try to read config file
	configData, err := os.ReadFile(SECOPS_NOTIFIER_CONFIG_FILE_PATH)
	if err != nil {
		log.Printf("Error reading config for patch task check: %v", err)
		return false
	}

	// Parse the config
	var config SecOpsNotifierConfig
	if err = json.Unmarshal(configData, &config); err != nil {
		log.Printf("Error parsing config for patch task check: %v", err)
		return false
	}

	// Skip API call if we don't have needed info
	if config.BaseURL == "" || config.Asset == "" || config.AssetType == "" {
		debugLog("Missing required config for patch task check")
		return false
	}

	// Make API call to check patch task status
	url := config.BaseURL + "/patch_management/fetch_ongoing_patch_task"

	// Get access token if available
	var accessToken string
	if config.Identifier != "" {
		accessToken, err = decrypt(config.Identifier, ENCRYPTION_KEY)
		if err != nil {
			log.Printf("Error decrypting access token: %v", err)
			return false
		}
	}

	// Prepare headers with authorization if token available
	headers := map[string]string{"Content-Type": "application/json"}
	if accessToken != "" {
		headers["Authorization"] = fmt.Sprintf("Bearer %s", accessToken)
	}

	// Prepare payload
	payload := map[string]string{
		"asset":      config.Asset,
		"asset_type": config.AssetType,
	}

	bodyJSON, err := json.Marshal(payload)
	if err != nil {
		log.Printf("Error marshaling payload: %v", err)
		return false
	}

	// Create request
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(bodyJSON))
	if err != nil {
		log.Printf("Error creating HTTP request: %v", err)
		return false
	}

	// Add headers
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	// Set timeout context
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req = req.WithContext(ctx)

	// Make the request
	resp, err := (&http.Client{}).Do(req)
	if err != nil {
		log.Printf("Error making HTTP request: %v", err)
		return false
	}
	defer resp.Body.Close()

	// Check response
	if resp.StatusCode == http.StatusOK {
		var r struct {
			RunningPatchStatus bool `json:"running_patch_status"`
		}

		if err := json.NewDecoder(resp.Body).Decode(&r); err == nil {
			debugLog("checkPatchTaskProcess result", r.RunningPatchStatus)
			return r.RunningPatchStatus
		} else {
			log.Printf("Error decoding response: %v", err)
		}
	} else {
		log.Printf("API returned non-200 status: %d", resp.StatusCode)
	}

	debugLog("checkPatchTaskProcess result false (default / error path)")
	return false
}

// createLocalWorkingDir creates a secure working directory
func createLocalWorkingDir(prefix, asset string) string {
	// Use a more secure location than temp
	securePath, err := getSecurePath()
	if err != nil {
		log.Printf("Error getting secure path: %v", err)
		return os.TempDir()
	}

	workingDir := filepath.Join(securePath, fmt.Sprintf("%s_%s_%s", prefix, asset, time.Now().Format("20060102150405")))

	if err := os.MkdirAll(workingDir, 0750); err != nil {
		log.Printf("Error creating working directory: %v", err)
		return os.TempDir()
	}

	return workingDir
}

// patchScan initiates a patch scan
func patchScan(c *SecOpsNotifierConfig) error {
	debugLog("patchScan start")
	log.Println("Initiating Patch Scan...")

	// Read patch binary config
	data, err := os.ReadFile(SECOPS_PATCH_BINARY_CONFIG_FILE_PATH)
	if err != nil {
		return fmt.Errorf("error reading patch binary config: %v", err)
	}

	// Parse config
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return fmt.Errorf("error parsing patch binary config: %v", err)
	}

	// Update configuration
	cfg["action"] = "Patch Scan"
	cfg["secops_notifier_config"] = c
	asset, _ := cfg["asset"].(string)
	localWorkingDir := createLocalWorkingDir("Patch_Scan", asset)
	cfg["working_dir"] = localWorkingDir

	// Save updated config
	bytesJSON, _ := json.Marshal(cfg)
	if err := os.WriteFile(SECOPS_PATCH_BINARY_CONFIG_FILE_PATH, bytesJSON, 0640); err != nil {
		return fmt.Errorf("error writing patch binary config: %v", err)
	}

	// Determine binary name based on OS
	var binName string
	if runtime.GOOS == "windows" {
		binName = SECOPS_WINDOWS_PATCH_BINARY_FILE_NAME
	} else if runtime.GOOS == "linux" {
		binName = SECOPS_LINUX_PATCH_BINARY_FILE_NAME
	} else if runtime.GOOS == "darwin" {
		binName = SECOPS_MAC_PATCH_BINARY_FILE_NAME
	} else {
		return fmt.Errorf("unsupported OS")
	}

	// Copy binaries to working directory
	if err := copyFile(SECOPS_PATCH_BINARY_FILE_PATH, filepath.Join(localWorkingDir, binName)); err != nil {
		return fmt.Errorf("error copying patch binary: %v", err)
	}

	if err := copyFile(SECOPS_PATCH_BINARY_CONFIG_FILE_PATH, filepath.Join(localWorkingDir, SECOPS_PATCH_BINARY_CONFIG_FILE_NAME)); err != nil {
		return fmt.Errorf("error copying patch binary config: %v", err)
	}

	// Set executable permissions on Unix-like systems
	if runtime.GOOS != "windows" {
		binaryPath := filepath.Join(localWorkingDir, binName)
		if err := os.Chmod(binaryPath, 0750); err != nil {
			log.Printf("Warning: Could not set executable permissions: %v", err)
		}
	}

	// Execute binary
	if runtime.GOOS == "windows" {
		cmd := exec.Command(filepath.Join(localWorkingDir, binName))
		cmd.Dir = localWorkingDir
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("error starting Windows patch scan: %v", err)
		}
		log.Println("Started Patch Scan binary (Windows)")
	} else {
		command := fmt.Sprintf("cd %s && nohup %s/%s > /dev/null 2>&1 &", localWorkingDir, localWorkingDir, binName)
		res := executeCommandWithTimeout(command, "", 5*time.Second)
		if res.Error != nil {
			log.Printf("Error starting patch scan: %s", res.Stderr)
			return fmt.Errorf("error starting Unix patch scan: %v", res.Error)
		}
		log.Println("Started Patch Scan binary")
	}

	debugLog("patchScan finished")
	return nil
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	// Check if source exists
	if _, err := os.Stat(src); os.IsNotExist(err) {
		return fmt.Errorf("source file does not exist: %v", err)
	}

	// Open source file
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("error opening source file: %v", err)
	}
	defer in.Close()

	// Create destination file
	out, err := os.Create(dst)
	if err != nil {
		return fmt.Errorf("error creating destination file: %v", err)
	}
	defer out.Close()

	// Copy contents
	if _, err = io.Copy(out, in); err != nil {
		return fmt.Errorf("error copying file contents: %v", err)
	}

	// Set secure permissions
	if runtime.GOOS != "windows" {
		if err := os.Chmod(dst, 0640); err != nil {
			return fmt.Errorf("error setting file permissions: %v", err)
		}
	}

	return nil
}

// macOS specific helper functions
func macDisplayNotification(msg string) {
	if runtime.GOOS != "darwin" {
		return
	}
	_ = exec.Command("/usr/bin/osascript", "-e", fmt.Sprintf(`display notification "%s" with title "SecOps Notifier"`, escapeAppleScriptString(msg))).Start()
}

func macOpenNotifierApp() {
	if runtime.GOOS != "darwin" {
		return
	}

	if SECOPS_NOTIFIER_FILE_PATH == "" {
		return
	}

	// Check if app exists before attempting to open it
	if _, err := os.Stat(SECOPS_NOTIFIER_FILE_PATH); err == nil {
		_ = exec.Command("open", SECOPS_NOTIFIER_FILE_PATH).Start()
		log.Println("Launched macOS notifier app")
	} else {
		log.Printf("Could not find macOS notifier app at %s: %v", SECOPS_NOTIFIER_FILE_PATH, err)
	}
}

func macIsAppRunning(name string) bool {
	if runtime.GOOS != "darwin" {
		return false
	}

	cmd := exec.Command("bash", "-c", fmt.Sprintf("pgrep -fl '%s' || true", name))
	out, err := cmd.CombinedOutput()
	if err != nil {
		log.Printf("Error checking if app is running: %v", err)
		return false
	}

	return strings.Contains(string(out), name)
}

// cleanupOldScripts removes old script files
func cleanupOldScripts() {
	if runtime.GOOS != "darwin" {
		return
	}

	// Clean up any scripts in /tmp that might have been created by older versions
	oldPaths := []string{
		"/tmp/secops_notifier_task.sh",
		"/tmp/secops_mac_reboot_now.sh",
	}

	for _, path := range oldPaths {
		if _, err := os.Stat(path); err == nil {
			if err := os.Remove(path); err != nil {
				log.Printf("Error removing old script %s: %v", path, err)
			} else {
				log.Printf("Removed old script: %s", path)
			}
		}
	}
}

// Main function
func main() {
	fmt.Println("SecOpsNotifierServer starting... (version=", VERSION, ", debug=", DEBUG, ")")
	debugLog("main entry")

	// Initialize the application
	if err := initializeApp(); err != nil {
		fmt.Printf("Error initializing application: %v\n", err)
		os.Exit(1)
	}
	defer logFile.Close()

	// Check for running instances
	acquired, err := acquireProcessLock()
	if err != nil || !acquired {
		log.Printf("Could not acquire process lock: %v", err)
		fmt.Printf("Another instance is already running. Exiting.\n")
		os.Exit(1)
	}
	defer releaseProcessLock()

	// Clean up old scripts (transitioning from /tmp to secure location)
	cleanupOldScripts()

	// Load configuration
	if err := loadConfig(); err != nil {
		log.Printf("Error loading configuration: %v", err)
		os.Exit(1)
	}

	// Check if reboot is required
	restartRequired, err := checkIfRebootRequired()
	if err != nil {
		log.Printf("Error checking reboot requirement: %v", err)
		os.Exit(1)
	}

	debugLog("rebootRequired=", restartRequired)
	log.Println("Reboot required:", restartRequired)

	// If reboot is required, manage the notification process
	if restartRequired {
		debugLog("enter reboot-required branch")
		log.Println("Service Started.....")

		// Platform-specific initialization
		if runtime.GOOS == "windows" {
			securePath, _ := getSecurePath()
			permissionsCommand := fmt.Sprintf(`$d="%s";Get-ChildItem -Path $d -Recurse | ForEach-Object { $acl=Get-Acl $_.FullName; $rule=New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\\Users","FullControl","Allow"); $acl.SetAccessRule($rule); Set-Acl $_.FullName $acl }; $dirAcl=Get-Acl $d; $rule=New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\\Users","FullControl","Allow"); $dirAcl.SetAccessRule($rule); Set-Acl $d $dirAcl`, securePath)
			if err := runPowerShellCommand(permissionsCommand); err != nil {
				log.Printf("Error setting permissions: %v", err)
			}
		} else if runtime.GOOS == "darwin" {
			// Check if app is running before launching
			if !macIsAppRunning("SecOpsRebootNotifier") {
				macOpenNotifierApp()
			}
			macDisplayNotification("Reboot required. Scheduling workflow started.")
		}

		// Main processing loop
		for {
			// Read configuration
			if err := loadConfig(); err != nil {
				log.Printf("Error reloading config: %v", err)
				time.Sleep(5 * time.Second)
				continue
			}

			scheduledTime := SECOPS_NOTIFIER_CONFIG.ScheduledTime
			debugLog("scheduledTime=", scheduledTime)

			if SECOPS_NOTIFIER_CONFIG.TaskScheduled {
				debugLog("task is scheduled")
			} else {
				debugLog("task is not scheduled")
			}

			// Format scheduled time if provided
			if scheduledTime != "" {
				t, err := time.Parse("2006-01-02 15:04:05", scheduledTime)
				if err == nil {
					scheduledTime = t.Format("2006-01-02 15:04:05")
				} else {
					log.Printf("Error parsing scheduled time: %v", err)
				}
			} else {
				// Set default scheduled time for Linux if not provided
				if runtime.GOOS == "linux" {
					currentTime := time.Now()
					switch SECOPS_NOTIFIER_CONFIG.RebootConfig {
					case REBOOT_NOW:
						scheduledTime = currentTime.Add(5 * time.Minute).Format("2006-01-02 15:04:05")
					case GRACEFUL_REBOOT:
						scheduledTime = currentTime.Add(15 * time.Minute).Format("2006-01-02 15:04:05")
					}
				}
			}

			// Handle reboot and scheduling logic
			if runtime.GOOS == "linux" {
				if SECOPS_NOTIFIER_CONFIG.RebootNow {
					if !checkPatchTaskProcess() {
						scheduleRebootNowTask(&SECOPS_NOTIFIER_CONFIG)

						// Update config atomically
						if err := updateConfig(map[string]interface{}{
							"task_scheduled": true,
							"reboot_now":     false,
						}); err != nil {
							log.Printf("Error updating config: %v", err)
						}
					}
				} else if !SECOPS_NOTIFIER_CONFIG.TaskScheduled {
					scheduleTask(scheduledTime) // Assumes function schedules immediate task for given time

					// Update config atomically
					if err := updateConfig(map[string]interface{}{
						"task_scheduled": true,
					}); err != nil {
						log.Printf("Error updating config: %v", err)
					}
				}
			} else {
				if SECOPS_NOTIFIER_CONFIG.RebootNow {
					err := deleteScheduledTask()
					if err != nil {
						log.Printf("Error while deleting task: %v", err)
					}

					if !checkPatchTaskProcess() {
						scheduleRebootNowTask(&SECOPS_NOTIFIER_CONFIG)

						// Update config atomically
						if err := updateConfig(map[string]interface{}{
							"task_scheduled": true,
							"reboot_now":     false,
						}); err != nil {
							log.Printf("Error updating config: %v", err)
						}
					}
				} else if !SECOPS_NOTIFIER_CONFIG.TaskScheduled {
					scheduleTask(scheduledTime)

					// Update config atomically
					if err := updateConfig(map[string]interface{}{
						"task_scheduled": true,
					}); err != nil {
						log.Printf("Error updating config: %v", err)
					}
				}
			}

			// Sleep between checks
			time.Sleep(1 * time.Second)
		}
	} else {
		// System does not need reboot or has been rebooted
		log.Println("Machine Rebooted Successfully.")
		time.Sleep(10 * time.Second)

		// Read configuration one more time
		if err := loadConfig(); err != nil {
			log.Printf("Error loading config after reboot: %v", err)
			os.Exit(1)
		}

		// Run patch scan after reboot
		if err := patchScan(&SECOPS_NOTIFIER_CONFIG); err != nil {
			log.Printf("Error running patch scan: %v", err)
		}

		// Clean up
		stopAndRemoveService()
	}
}
