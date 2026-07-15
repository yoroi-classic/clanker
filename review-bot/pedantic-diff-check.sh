#!/usr/bin/env bash
set -euo pipefail

BASE_SHA="${REVIEW_BOT_DIFF_BASE_SHA:-${REVIEW_BOT_BASE_SHA:?REVIEW_BOT_BASE_SHA is required}}"
HEAD_SHA="${REVIEW_BOT_HEAD_SHA:?REVIEW_BOT_HEAD_SHA is required}"

tmp_additions="$(mktemp)"
trap 'rm -f "$tmp_additions"' EXIT

git diff --no-color --unified=0 --diff-filter=ACMRT --no-ext-diff "$BASE_SHA" "$HEAD_SHA" |
  awk '
    /^diff --git / {
      file = ""
      next
    }
    /^\+\+\+ b\// {
      file = substr($0, 7)
      next
    }
    /^\+\+\+ \/dev\/null/ {
      file = ""
      next
    }
    /^@@ / {
      if (match($0, /\+([0-9]+)/)) {
        new_line = substr($0, RSTART + 1, RLENGTH - 1) + 0
      }
      next
    }
    file != "" && /^\+/ && !/^\+\+\+/ {
      print file "\t" new_line "\t" substr($0, 2)
      new_line++
      next
    }
    file != "" && !/^-/ {
      new_line++
    }
  ' >"$tmp_additions"

if [[ ! -s "$tmp_additions" ]]; then
  exit 0
fi

findings=0
quote_re=$'["\'`]'

matches_ere() {
  local text="$1"
  local regex="$2"

  printf '%s\n' "$text" | LC_ALL=C grep -Eiq -- "$regex"
}

skip_path() {
  case "$1" in
    package-lock.json|*/package-lock.json|yarn.lock|*/yarn.lock|pnpm-lock.yaml|*/pnpm-lock.yaml)
      return 0
      ;;
    *.lock|*.map|*.snap|*.snapshot)
      return 0
      ;;
    dist/*|*/dist/*|build/*|*/build/*|coverage/*|*/coverage/*|node_modules/*|*/node_modules/*)
      return 0
      ;;
    flow-typed/*|*/flow-typed/*|docs/*|*/docs/*|*.md|*.mdx)
      return 0
      ;;
    csl-mobile-bridge/cpp/NativeCslMobileBridgeModule.cpp)
      return 0
      ;;
  esac

  return 1
}

test_or_fixture_path() {
  case "$1" in
    test/*|tests/*|*/test/*|*/tests/*|*/__tests__/*|fixtures/*|*/fixtures/*|examples/*|*/examples/*)
      return 0
      ;;
    *.test.*|*.spec.*|*.stories.*)
      return 0
      ;;
  esac

  return 1
}

strip_string_literals() {
  local input="$1"
  local output=""
  local quote=""
  local escaped=0
  local char

  for ((index = 0; index < ${#input}; index++)); do
    char="${input:index:1}"

    if [[ -n "$quote" ]]; then
      if [[ "$escaped" -eq 1 ]]; then
        escaped=0
        continue
      fi
      if [[ "$char" == "\\" ]]; then
        escaped=1
        continue
      fi
      if [[ "$char" == "$quote" ]]; then
        output+="$char"
        quote=""
      fi
      continue
    fi

    if [[ "$char" == "'" || "$char" == '"' || "$char" == '`' ]]; then
      quote="$char"
      output+="$char"
      continue
    fi

    output+="$char"
  done

  printf '%s' "$output"
}

sanitize() {
  printf '%s' "$1" |
    sed -E \
      -e 's/["'\''][^"'\'']{12,}["'\'']/"<redacted>"/g' \
      -e 's/([A-Za-z_]*(mnemonic|seed|privateKey|private_key|password|passphrase|secret)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*)[^,;) ]+/\1<redacted>/Ig' |
    cut -c 1-180
}

report() {
  local category="$1"
  local file="$2"
  local line="$3"
  local content="$4"

  findings=1
  printf 'pedantic wallet diff check: %s\n' "$category"
  printf '  %s:%s\n' "$file" "$line"
  printf '  added: %s\n\n' "$(sanitize "$content")"
}

while IFS=$'\t' read -r file line content; do
  if skip_path "$file"; then
    continue
  fi

  lower="${content,,}"
  stripped="$(strip_string_literals "$content")"
  stripped_lower="${stripped,,}"
  file_lower="${file,,}"
  secret_terms='mnemonic|seed[_. -]?phrase|seedphrase|recovery[_. -]?phrase|recoveryphrase|private[_. -]?key|privatekey|root[_. -]?key|rootkey|spending[_. -]?password|spendingpassword|passphrase|xprv|xpriv|api[_. -]?key|apikey|access[_. -]?token|accesstoken|refresh[_. -]?token|refreshtoken|auth[_. -]?token|authtoken|authorization|secret'

  if matches_ere "$stripped_lower" '(console\.|logger|log\(|sentry|analytics|telemetry|track\(|captureexception|capturemessage)' &&
    matches_ere "$stripped_lower" "$secret_terms"; then
    report "possible sensitive wallet material in logging or telemetry" "$file" "$line" "$content"
  fi

  if matches_ere "$lower" 'eval[[:space:]]*\(|new[[:space:]]+function[[:space:]]*\(' ||
    matches_ere "$lower" "function[[:space:]]*\\([[:space:]]*$quote_re" ||
    matches_ere "$lower" "set(timeout|interval)[[:space:]]*\\([[:space:]]*$quote_re"; then
    report "dynamic code execution added" "$file" "$line" "$content"
  fi

  if matches_ere "$lower" 'dangerouslysetinnerhtml|innerhtml[[:space:]]*=|outerhtml[[:space:]]*=|insertadjacenthtml[[:space:]]*\('; then
    report "raw HTML injection surface added" "$file" "$line" "$content"
  fi

  if matches_ere "$lower" 'node_tls_reject_unauthorized[[:space:]]*[:=]?[[:space:]]*["'\'']?0|rejectunauthorized[[:space:]]*:[[:space:]]*false|strictssl[[:space:]]*:[[:space:]]*false|strict-ssl[[:space:]]*[:=][[:space:]]*false|insecureskipverify[[:space:]]*:[[:space:]]*true|danger_accept_invalid_(certs|hostnames)[[:space:]]*\([[:space:]]*true|curl[[:space:]].*(-k|--insecure)' ||
    matches_ere "$lower" 'insecure[[:space:]_-]*tls'; then
    report "TLS or certificate verification weakening added" "$file" "$line" "$content"
  fi

  if matches_ere "$stripped_lower" '(localstorage|sessionstorage|asyncstorage)\.setitem|\b(chrome|browser)\.storage\.(sync|local)\.set|navigator\.clipboard\.writetext|clipboard\.setstring|urlsearchparams|searchparams\.set|location\.(href|assign|replace)' &&
    matches_ere "$stripped_lower" "$secret_terms"; then
    report "secret material written to unsafe storage, clipboard, or URL surface" "$file" "$line" "$content"
  fi

  if ! test_or_fixture_path "$file" &&
    {
      matches_ere "$lower" "(const|let|var)[[:space:]]+(mnemonic|seedphrase|recoveryphrase|privatekey|rootkey|xprv|xpriv|passphrase)\\b[^=]*=[[:space:]]*$quote_re" ||
        matches_ere "$lower" "(privatekey|bip32privatekey)\\.(from_hex|from_bech32|from_bytes)[[:space:]]*\\([[:space:]]*$quote_re" ||
        matches_ere "$lower" "mnemonictoentropy[[:space:]]*\\([[:space:]]*$quote_re" ||
        matches_ere "$lower" "(privatekey|private_key|rootkey|root_key)[[:space:]]*:[[:space:]]*$quote_re"
    }; then
    report "hardcoded wallet secret material added" "$file" "$line" "$content"
  fi

  if [[ "$file_lower" =~ (^|/)(manifest|.*config).*\.(json|js|ts|cjs|mjs)$ ]] &&
    matches_ere "$lower" '"<all_urls>"|"clipboardread"|"webrequestblocking"|"debugger"|"nativemessaging"|unsafe-eval|script-src[^;]*(\*|http:)'; then
    report "extension permission or CSP surface expanded" "$file" "$line" "$content"
  fi

  if [[ "$lower" =~ math\.random && "$lower" =~ (mnemonic|seed|private[_.\ -]?key|root[_.\ -]?key|nonce|salt|iv|entropy|wallet|address) ]]; then
    report "non-cryptographic randomness near wallet or key material" "$file" "$line" "$content"
  fi

  if [[ "$lower" =~ (parsefloat|parseint|number\(|tonumber\(\)) &&
        "$lower" =~ (lovelace|amount|balance|quantity|asset|token|ada|fee|utxo|coin) ]]; then
    report "plain numeric conversion near monetary value" "$file" "$line" "$content"
  fi
done <"$tmp_additions"

if [[ "$findings" -ne 0 ]]; then
  exit 1
fi
