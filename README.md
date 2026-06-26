# Phase 1A Data Extractor — Workday Customer Extract

Extracts all customer records from the Workday **Revenue Management** SOAP API (`Get_Customers` v46.1) and writes them to a timestamped CSV file.

## Requirements

- macOS (tested on macOS 15+)
- `curl` and `python3` — both included with macOS by default
- A Workday API client configured with the **Revenue Management** scope and a valid refresh token

## Setup

1. Copy the example env file and fill in your credentials:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env`:

   | Variable | Description |
   |---|---|
   | `WORKDAY_TOKEN_ENDPOINT` | OAuth 2.0 token URL (`/ccx/oauth2/<tenant>/token`) |
   | `WORKDAY_SOAP_ENDPOINT` | Revenue Management SOAP URL (`/ccx/service/<tenant>/Revenue_Management/v46.1`) |
   | `WORKDAY_CLIENT_ID` | API client ID from *Register API Client* |
   | `WORKDAY_CLIENT_SECRET` | API client secret |
   | `WORKDAY_REFRESH_TOKEN` | Refresh token from *Manage Refresh Tokens for Integrations* |
   | `WORKDAY_API_VERSION` | API version (default: `v46.1`) |
   | `PAGE_SIZE` | Records per page, max 999 (default: `999`) |
   | `MAX_CONCURRENT` | Pages fetched in parallel per batch (default: `5`) |
   | `OUTPUT_DIR` | Output folder relative to the script (default: `extracts`) |

3. Make the script executable (first time only):

   ```bash
   chmod +x extract_customers.sh
   ```

## Usage

```bash
./extract_customers.sh
```

The script prints progress as it runs:

```
Requesting Workday access token...
Access token obtained.
Probing total record count...
Found 11432 customers across 12 page(s).
Starting extraction → extracts/workday_customers_20260625_143022.csv
  Fetching pages 1–5 in parallel...
  Fetching pages 6–10 in parallel...
  Fetching pages 11–12 in parallel...
  All pages fetched. Parsing...

Done: 11432 customers written to:
  extracts/workday_customers_20260625_143022.csv
```

## Output

Files are written to `extracts/` and named `workday_customers_YYYYMMDD_HHMMSS.csv`. The `extracts/` directory is git-ignored.

### CSV columns

| Column | Source (Workday field) |
|---|---|
| `Customer_ID` | `Customer_Data/Customer_ID` |
| `Name` | `Business_Entity_Data/Business_Entity_Name` |
| `Customer_Category` | `Customer_Category_Reference` (`Customer_Category_ID`) |
| `Address_Line_1` | Primary address `Address_Line_Data` (type `ADDRESS_LINE_1`) |
| `Address_Line_2` | Primary address `Address_Line_Data` (type `ADDRESS_LINE_2`) |
| `City` | Primary address `Municipality` |
| `State_Code` | Primary address `Country_Region_Reference` (`ISO_3166-2_Code`) |
| `Postcode` | Primary address `Postal_Code` |
| `Country_Code` | Primary address `Country_Reference` (`ISO_3166-1_Alpha-2_Code`) |
| `Email` | Primary `Email_Address_Data/Email_Address` |
| `Delivery_Type` | All `Invoice_Delivery_Type_Reference` values, joined with `/` |

## Repository structure

```
.
├── extract_customers.sh   # Main extraction script
├── .env.example           # Credential template — copy to .env
├── .gitignore             # Excludes .env and extracts/
├── sample csvs/           # Reference output showing expected CSV format
└── README.md
```
