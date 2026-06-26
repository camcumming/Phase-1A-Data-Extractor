#!/usr/bin/env bash
# Extracts all Workday customer records via the Get_Customers SOAP service
# and writes them to a timestamped CSV under ./extracts/
#
# Requires: curl, python3 (both standard on macOS)
# Usage:    ./extract_customers.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load .env ────────────────────────────────────────────────────────────────

ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env not found. Copy .env.example to .env and fill in your credentials." >&2
    exit 1
fi
set -o allexport
source "$ENV_FILE"
set +o allexport

# ── Validate required variables ───────────────────────────────────────────────

REQUIRED_VARS=(
    WORKDAY_TOKEN_ENDPOINT
    WORKDAY_SOAP_ENDPOINT
    WORKDAY_CLIENT_ID
    WORKDAY_CLIENT_SECRET
    WORKDAY_REFRESH_TOKEN
)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env" >&2
        exit 1
    fi
done

API_VERSION="${WORKDAY_API_VERSION:-v46.1}"
PAGE_SIZE="${PAGE_SIZE:-999}"
MAX_CONCURRENT="${MAX_CONCURRENT:-5}"
OUTPUT_DIR="$SCRIPT_DIR/${OUTPUT_DIR:-extracts}"

# ── Setup output ──────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_CSV="$OUTPUT_DIR/workday_customers_${TIMESTAMP}.csv"

# ── Temp directory (cleaned up on exit) ──────────────────────────────────────

TEMP_DIR=$(mktemp -d /tmp/wd_soap_XXXXXX)
PARSER_PY=$(mktemp /tmp/wd_parser_XXXXXX.py)
trap 'rm -rf "$TEMP_DIR" "$PARSER_PY"' EXIT

# ── Write Python XML parser ───────────────────────────────────────────────────

cat > "$PARSER_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
Parse a single page of a Workday Get_Customers SOAP response and append
matching columns to a CSV.  Prints the number of rows written to stdout.

Args: <response_xml_path> <output_csv_path>
"""
import sys
import csv
import xml.etree.ElementTree as ET

WD = 'urn:com.workday/bsvc'

def text(el, *tags):
    cur = el
    for tag in tags:
        if cur is None:
            return ''
        cur = cur.find(f'{{{WD}}}{tag}')
    return (cur.text or '').strip() if cur is not None else ''

def find_id(el, id_type):
    if el is None:
        return ''
    for id_el in el.findall(f'{{{WD}}}ID'):
        if id_el.get(f'{{{WD}}}type') == id_type:
            return (id_el.text or '').strip()
    return ''

def primary_address(contact):
    """Return the Address_Data element whose Usage_Data has Primary='1'."""
    if contact is None:
        return None
    for addr in contact.findall(f'{{{WD}}}Address_Data'):
        for td in addr.findall(f'.//{{{WD}}}Type_Data'):
            if td.get(f'{{{WD}}}Primary') == '1':
                return addr
    return contact.find(f'{{{WD}}}Address_Data')

def primary_email(contact):
    """Return the email address from the primary Email_Address_Data entry."""
    if contact is None:
        return ''
    for ed in contact.findall(f'{{{WD}}}Email_Address_Data'):
        for td in ed.findall(f'.//{{{WD}}}Type_Data'):
            if td.get(f'{{{WD}}}Primary') == '1':
                el = ed.find(f'{{{WD}}}Email_Address')
                return (el.text or '').strip() if el is not None else ''
    return ''

xml_path, csv_path = sys.argv[1], sys.argv[2]

try:
    root = ET.parse(xml_path).getroot()
except ET.ParseError as e:
    print(f"ERROR: Could not parse XML response: {e}", file=sys.stderr)
    sys.exit(1)

# Surface any SOAP fault clearly before attempting to iterate customers
fault = root.find(f'.//{{{WD}}}Workday_Common_Error')
if fault is None:
    fault = root.find('.//{http://schemas.xmlsoap.org/soap/envelope/}Fault')
if fault is not None:
    fault_msg = root.find('.//{http://schemas.xmlsoap.org/soap/envelope/}faultstring')
    desc      = root.find(f'.//{{{WD}}}Description')
    msg = (fault_msg.text if fault_msg is not None
           else desc.text if desc is not None
           else 'Unknown SOAP fault — check raw response')
    print(f"ERROR: SOAP Fault: {msg}", file=sys.stderr)
    sys.exit(1)

rows = []
for customer in root.findall(f'.//{{{WD}}}Customer'):
    data = customer.find(f'{{{WD}}}Customer_Data')
    if data is None:
        continue

    customer_id = text(data, 'Customer_ID')
    name        = text(data, 'Business_Entity_Data', 'Business_Entity_Name')
    category    = find_id(data.find(f'{{{WD}}}Customer_Category_Reference'), 'Customer_Category_ID')

    contact = data.find(f'{{{WD}}}Business_Entity_Data/{{{WD}}}Contact_Data')
    addr    = primary_address(contact)

    addr1 = addr2 = city = state = postcode = country = ''
    if addr is not None:
        for line in addr.findall(f'{{{WD}}}Address_Line_Data'):
            val = (line.text or '').strip()
            if line.get(f'{{{WD}}}Type') == 'ADDRESS_LINE_1':
                addr1 = val
            elif line.get(f'{{{WD}}}Type') == 'ADDRESS_LINE_2':
                addr2 = val
        city     = text(addr, 'Municipality')
        state    = find_id(addr.find(f'{{{WD}}}Country_Region_Reference'), 'ISO_3166-2_Code')
        postcode = text(addr, 'Postal_Code')
        country  = find_id(addr.find(f'{{{WD}}}Country_Reference'), 'ISO_3166-1_Alpha-2_Code')

    email = primary_email(contact)

    delivery_types = [
        find_id(ref, 'Document_Delivery_Type_ID')
        for ref in data.findall(f'{{{WD}}}Invoice_Delivery_Type_Reference')
    ]
    delivery_type = '/'.join(t for t in delivery_types if t)

    rows.append([
        customer_id, name, category,
        addr1, addr2, city, state, postcode, country,
        email, delivery_type,
    ])

with open(csv_path, 'a', newline='', encoding='utf-8') as f:
    csv.writer(f).writerows(rows)

print(len(rows))
PYEOF

# ── Get OAuth access token ────────────────────────────────────────────────────

echo "Requesting Workday access token..."

TOKEN_JSON=$(curl -s -X POST "$WORKDAY_TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$WORKDAY_REFRESH_TOKEN" \
    --data-urlencode "client_id=$WORKDAY_CLIENT_ID" \
    --data-urlencode "client_secret=$WORKDAY_CLIENT_SECRET")

ACCESS_TOKEN=$(python3 - "$TOKEN_JSON" << 'PYEOF'
import sys, json
try:
    d = json.loads(sys.argv[1])
except json.JSONDecodeError as e:
    print(f"ERROR: Token endpoint did not return JSON: {e}", file=sys.stderr)
    sys.exit(1)
if 'access_token' not in d:
    print(f"ERROR: {d.get('error', 'unknown')} — {d.get('error_description', sys.argv[1])}", file=sys.stderr)
    sys.exit(1)
print(d['access_token'])
PYEOF
)

echo "Access token obtained."

# ── Helper: read a wd: namespace value from a saved XML file ─────────────────

wd_value() {
    local xml_file="$1" tag="$2"
    python3 - "$xml_file" "$tag" << 'PYEOF'
import sys
import xml.etree.ElementTree as ET
WD = 'urn:com.workday/bsvc'
root = ET.parse(sys.argv[1]).getroot()
el = root.find(f'.//{{{WD}}}{sys.argv[2]}')
print((el.text or '0').strip() if el is not None else '0')
PYEOF
}

# ── SOAP paged request ────────────────────────────────────────────────────────

fetch_page() {
    local page="$1" count="${2:-$PAGE_SIZE}"
    curl -s -X POST "$WORKDAY_SOAP_ENDPOINT" \
        -H "Content-Type: text/xml;charset=UTF-8" \
        -H 'SOAPAction: ""' \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -d "<?xml version='1.0' encoding='UTF-8'?>
<soapenv:Envelope xmlns:soapenv=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:bsvc=\"urn:com.workday/bsvc\">
  <soapenv:Body>
    <bsvc:Get_Customers_Request bsvc:version=\"${API_VERSION}\">
      <bsvc:Response_Filter>
        <bsvc:Page>${page}</bsvc:Page>
        <bsvc:Count>${count}</bsvc:Count>
      </bsvc:Response_Filter>
      <bsvc:Response_Group>
        <bsvc:Include_Reference>1</bsvc:Include_Reference>
        <bsvc:Include_Customer_Data>1</bsvc:Include_Customer_Data>
        <bsvc:Include_Customer_Balance>0</bsvc:Include_Customer_Balance>
        <bsvc:Include_Customer_Activity_Detail>0</bsvc:Include_Customer_Activity_Detail>
      </bsvc:Response_Group>
    </bsvc:Get_Customers_Request>
  </soapenv:Body>
</soapenv:Envelope>"
}

# ── Main extraction ───────────────────────────────────────────────────────────

printf 'Customer_ID,Name,Customer_Category,Address_Line_1,Address_Line_2,City,State_Code,Postcode,Country_Code,Email,Delivery_Type\n' > "$OUTPUT_CSV"

TOTAL_ROWS=0

# Probe: one record to discover pagination metadata without pulling full data
echo "Probing total record count..."
fetch_page 1 1 > "$TEMP_DIR/probe.xml"

TOTAL_RESULTS=$(wd_value "$TEMP_DIR/probe.xml" "Total_Results")
TOTAL_PAGES=$(wd_value   "$TEMP_DIR/probe.xml" "Total_Pages")

if [[ "$TOTAL_RESULTS" -eq 0 ]]; then
    echo "No customers found. Exiting."
    exit 0
fi

[[ "$TOTAL_PAGES" -lt 1 ]] && TOTAL_PAGES=1

echo "Found ${TOTAL_RESULTS} customers across ${TOTAL_PAGES} page(s)."
echo "Starting extraction → $OUTPUT_CSV"

# Fetch phase: fire up to MAX_CONCURRENT pages in parallel, then wait for the
# batch before launching the next — each page lands in its own temp file.
for ((batch_start=1; batch_start<=TOTAL_PAGES; batch_start+=MAX_CONCURRENT)); do
    batch_end=$((batch_start + MAX_CONCURRENT - 1))
    [[ $batch_end -gt $TOTAL_PAGES ]] && batch_end=$TOTAL_PAGES

    echo "  Fetching pages ${batch_start}–${batch_end} in parallel..."
    for ((page=batch_start; page<=batch_end; page++)); do
        fetch_page "$page" > "$TEMP_DIR/page_$(printf '%04d' $page).xml" &
    done
    wait
done

echo "  All pages fetched. Parsing..."

# Parse phase: process pages in order so CSV rows are stable across runs.
for ((page=1; page<=TOTAL_PAGES; page++)); do
    ROW_COUNT=$(python3 "$PARSER_PY" "$TEMP_DIR/page_$(printf '%04d' $page).xml" "$OUTPUT_CSV")
    TOTAL_ROWS=$((TOTAL_ROWS + ROW_COUNT))
done

echo ""
echo "Done: ${TOTAL_ROWS} customers written to:"
echo "  $OUTPUT_CSV"
