#!/usr/bin/env bash
# scripts/lib/students_csv.sh
# CSV parsing + validation for students.csv (Sprint 2).
#
# Schema:
#   Required header columns (in any order): name, email, slug, parent_email
#   Optional override columns:               max_budget, daily_budget,
#                                            weekly_budget, rpm_limit, tpm_limit
#
# Constraint: no commas allowed inside any field. Document this in
# templates/students.csv.example.
#
# Portable: bash 3.2 (macOS) and bash 5+ (Ubuntu 24.04). Pure bash + IFS, no awk.

if [[ -n "${CULTIVLAB_STUDENTS_CSV_LOADED:-}" ]]; then
  return 0
fi
CULTIVLAB_STUDENTS_CSV_LOADED=1

_STUDENTS_CSV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CULTIVLAB_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "${_STUDENTS_CSV_DIR}/common.sh"
fi

STUDENTS_CSV_REQUIRED_COLS=(name email slug parent_email)
STUDENTS_CSV_OPTIONAL_COLS=(max_budget daily_budget weekly_budget rpm_limit tpm_limit)
STUDENTS_CSV_SLUG_REGEX='^[a-z][a-z0-9-]{2,30}$'

# Internal: header column names parsed from row 1, in declared order.
_CSV_HEADER_NAMES=()
_CSV_HEADER_FIELDS=0

# _students_csv_index_of <col_name>
# Prints the 0-based column index for <col_name>, returns 0 on hit, 1 on miss.
_students_csv_index_of() {
  local name="$1"
  local i
  for (( i = 0; i < ${#_CSV_HEADER_NAMES[@]}; i++ )); do
    if [[ "${_CSV_HEADER_NAMES[$i]}" == "${name}" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# Strip CR (Windows line endings) and trim leading/trailing whitespace.
_students_csv_clean() {
  local v="$1"
  v="${v//$'\r'/}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Split a CSV line into the named array, preserving trailing empty fields.
# Bash's `read -a` drops a single trailing empty field; we append a sentinel
# and strip it afterwards so a row like "a,b,c,,," yields 6 fields, not 5.
# Usage: _students_csv_split <varname> <line>
_students_csv_split() {
  local __out="$1"
  local __line="$2"
  local __parts
  IFS=',' read -ra __parts <<< "${__line},__CSV_SENTINEL__"
  unset "__parts[$((${#__parts[@]} - 1))]"
  # Reassign as a contiguous array under the caller's chosen name.
  eval "${__out}=(\"\${__parts[@]+\"\${__parts[@]}\"}\")"
}

# Parse the header line into _CSV_HEADER_NAMES. Validates required cols.
_students_csv_parse_header() {
  local header_line="$1"
  _CSV_HEADER_NAMES=()
  local parts
  _students_csv_split parts "${header_line}"
  local part
  for part in ${parts[@]+"${parts[@]}"}; do
    _CSV_HEADER_NAMES+=("$(_students_csv_clean "${part}")")
  done
  _CSV_HEADER_FIELDS=${#_CSV_HEADER_NAMES[@]}

  local col
  for col in "${STUDENTS_CSV_REQUIRED_COLS[@]}"; do
    if ! _students_csv_index_of "${col}" >/dev/null; then
      log_error "students.csv header missing required column: ${col}"
      return 1
    fi
  done
  return 0
}

# _students_csv_optional_value <col_name> <default> -- <field_0> <field_1> ...
# Resolves an optional column's value for the current row, falling back to
# <default> when the column isn't in the header or the cell is empty.
_students_csv_optional_value() {
  local col_name="$1"; shift
  local default="$1"; shift
  shift  # discard "--"
  local fields_array=("$@")

  local idx
  if ! idx="$(_students_csv_index_of "${col_name}")"; then
    printf '%s' "${default}"
    return 0
  fi
  if [[ "${idx}" -ge "${#fields_array[@]}" ]]; then
    printf '%s' "${default}"
    return 0
  fi
  local v
  v="$(_students_csv_clean "${fields_array[$idx]}")"
  if [[ -z "${v}" ]]; then
    printf '%s' "${default}"
  else
    printf '%s' "${v}"
  fi
}

# ----------------------------------------------------------------------------
# students_csv_validate <path>
# Returns 0 on success. Exits 1 on first violation with a structured error log
# citing the offending line number.
#
# Checks: file exists, header has required cols, row count == COHORT_SIZE,
#         every slug matches the regex, every required field is non-empty,
#         no duplicate slugs, no duplicate emails, field count per row matches
#         header.
# ----------------------------------------------------------------------------
students_csv_validate() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    log_error "students.csv not found at: ${path}"
    exit 1
  fi

  require_env COHORT_SIZE

  local lineno=0
  local data_rows=0
  local seen_slugs=()
  local seen_emails=()
  local header_parsed=0
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    if [[ -z "$(_students_csv_clean "${line}")" ]]; then
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ "${header_parsed}" -eq 0 ]]; then
      if ! _students_csv_parse_header "${line}"; then
        log_error "students.csv header invalid at line ${lineno}"
        exit 1
      fi
      header_parsed=1
      continue
    fi

    local fields
    _students_csv_split fields "${line}"
    if [[ ${#fields[@]} -ne ${_CSV_HEADER_FIELDS} ]]; then
      log_error "students.csv line ${lineno}: expected ${_CSV_HEADER_FIELDS} fields, got ${#fields[@]} (commas inside fields are not allowed)"
      exit 1
    fi

    local slug email name parent_email idx
    idx="$(_students_csv_index_of slug)"
    slug="$(_students_csv_clean "${fields[$idx]}")"
    if ! [[ "${slug}" =~ ${STUDENTS_CSV_SLUG_REGEX} ]]; then
      log_error "students.csv line ${lineno}: invalid slug '${slug}' (must match ${STUDENTS_CSV_SLUG_REGEX})"
      exit 1
    fi

    idx="$(_students_csv_index_of email)"
    email="$(_students_csv_clean "${fields[$idx]}")"
    if [[ -z "${email}" ]]; then
      log_error "students.csv line ${lineno}: email is empty"
      exit 1
    fi

    idx="$(_students_csv_index_of name)"
    name="$(_students_csv_clean "${fields[$idx]}")"
    if [[ -z "${name}" ]]; then
      log_error "students.csv line ${lineno}: name is empty"
      exit 1
    fi

    idx="$(_students_csv_index_of parent_email)"
    parent_email="$(_students_csv_clean "${fields[$idx]}")"
    if [[ -z "${parent_email}" ]]; then
      log_error "students.csv line ${lineno}: parent_email is empty"
      exit 1
    fi

    local s e
    for s in ${seen_slugs[@]+"${seen_slugs[@]}"}; do
      if [[ "${s}" == "${slug}" ]]; then
        log_error "students.csv line ${lineno}: duplicate slug '${slug}'"
        exit 1
      fi
    done
    seen_slugs+=("${slug}")

    for e in ${seen_emails[@]+"${seen_emails[@]}"}; do
      if [[ "${e}" == "${email}" ]]; then
        log_error "students.csv line ${lineno}: duplicate email '${email}'"
        exit 1
      fi
    done
    seen_emails+=("${email}")

    data_rows=$((data_rows + 1))
  done < "${path}"

  if [[ "${header_parsed}" -eq 0 ]]; then
    log_error "students.csv has no header row"
    exit 1
  fi

  if [[ "${data_rows}" -ne "${COHORT_SIZE}" ]]; then
    log_error "students.csv data rows (${data_rows}) != COHORT_SIZE (${COHORT_SIZE})"
    exit 1
  fi

  log_info "students.csv validated: ${data_rows} rows, all slugs and emails unique"
  return 0
}

# ----------------------------------------------------------------------------
# students_csv_iter <path> <callback_fn>
# Invokes <callback_fn> once per data row with positional args:
#   <name> <email> <slug> <parent_email> <max_budget> <daily_budget> <weekly_budget> <rpm_limit> <tpm_limit>
# Optional fields fall back to STUDENT_* env defaults when absent or empty.
#
# Caller is responsible for running students_csv_validate first; iter does
# minimal sanity checks only (existence, header presence).
# ----------------------------------------------------------------------------
students_csv_iter() {
  local path="$1"
  local callback="$2"

  require_env STUDENT_MAX_BUDGET STUDENT_DAILY_BUDGET STUDENT_WEEKLY_BUDGET \
    STUDENT_RPM_LIMIT STUDENT_TPM_LIMIT

  if [[ ! -f "${path}" ]]; then
    log_error "students.csv not found at: ${path}"
    return 1
  fi

  local header_parsed=0
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "$(_students_csv_clean "${line}")" ]]; then
      continue
    fi
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ "${header_parsed}" -eq 0 ]]; then
      _students_csv_parse_header "${line}" || return 1
      header_parsed=1
      continue
    fi

    local fields
    _students_csv_split fields "${line}"

    local name email slug parent_email
    name="$(_students_csv_clean "${fields[$(_students_csv_index_of name)]}")"
    email="$(_students_csv_clean "${fields[$(_students_csv_index_of email)]}")"
    slug="$(_students_csv_clean "${fields[$(_students_csv_index_of slug)]}")"
    parent_email="$(_students_csv_clean "${fields[$(_students_csv_index_of parent_email)]}")"

    local max_budget daily_budget weekly_budget rpm_limit tpm_limit
    max_budget="$(_students_csv_optional_value max_budget "${STUDENT_MAX_BUDGET}" -- "${fields[@]}")"
    daily_budget="$(_students_csv_optional_value daily_budget "${STUDENT_DAILY_BUDGET}" -- "${fields[@]}")"
    weekly_budget="$(_students_csv_optional_value weekly_budget "${STUDENT_WEEKLY_BUDGET}" -- "${fields[@]}")"
    rpm_limit="$(_students_csv_optional_value rpm_limit "${STUDENT_RPM_LIMIT}" -- "${fields[@]}")"
    tpm_limit="$(_students_csv_optional_value tpm_limit "${STUDENT_TPM_LIMIT}" -- "${fields[@]}")"

    "${callback}" "${name}" "${email}" "${slug}" "${parent_email}" \
      "${max_budget}" "${daily_budget}" "${weekly_budget}" "${rpm_limit}" "${tpm_limit}"
  done < "${path}"

  return 0
}
