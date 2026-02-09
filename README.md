# Jira Export Logwork (Multi-user)

A command-line utility to export **Jira worklogs for multiple users**, supporting both **Windows (Batch + PowerShell)** and **Linux/macOS (Bash)**.  
Designed for **time tracking, reporting, auditing, and accounting** use cases.

---

## Features

- Export worklogs for multiple Jira users
- Automatically resolve Jira `accountId` from user email
- Filter worklogs by:
  - JQL scope
  - Date range (FROM / TO)
- Generate CSV reports:
  - `summary.csv` – total time per issue
  - `detail.csv` – detailed worklogs
- Automatic grand total (seconds & hours)
- Retry handling for Jira API errors:
  - HTTP 429 (rate limit)
  - HTTP 5xx (server errors)
- Parallel processing (Bash version)
- Compatible with Jira Cloud REST API v3

---

## Requirements

### Common
- Jira Cloud
- Jira API Token

### Windows
- Windows 10 / 11
- PowerShell 5.1+

### Linux / macOS
- Bash 4+
- curl
- jq
- awk

---

## Repository Structure
├── LICENSE
├── README.md
├── ubuntu
│   ├── jira-export-logwork.conf
│   └── jira-export-logwork-multiuser.sh
└── window
    ├── jira-export-logwork.conf
    └── jira-export-logwork-multiuser.bat

## Usage

## Windows (Batch + PowerShell):
Run by double-clicking: jira-export-logwork-multiuser.bat

## Linux / macOS (Bash):
chmod +x jira-export-logwork-multiuser.sh
./jira-export-logwork-multiuser.sh or ./jira-export-logwork-multiuser.sh -c path/to/jira-export-logwork.conf

## Output Structure
jira_worklogs_export_YYYYMMDD_HHMMSS/
├─ user_a_example_com/
│  ├─ summary.csv
│  └─ detail.csv
├─ user_b_example_com/
│  ├─ summary.csv
│  └─ detail.csv