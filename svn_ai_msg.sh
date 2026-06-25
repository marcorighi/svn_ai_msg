#!/usr/bin/env bash
set -u
set -o pipefail

# ==================================================
# svn_ai_msg.sh
# Stable conservative SVN AI commit-message helper
# ==================================================

MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}"
TARGET="."
CREATIVITY_LEVEL=3
DRY_RUN=0
COMMIT_SUGGESTION="${SVN_AI_SUGGESTION:-}"
COMMIT_GUIDANCE=""
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/generate}"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"

# --------------------------------------------------
# Host-specific defaults
# Override anytime with: OLLAMA_NUM_CTX=2048 ./svn_ai_msg.sh
# 1024 - 1280 - 1536 - 1792 - 2048 - 2304 - 2560 - 2816 - 3072 - 3328 - 3584 - 3840 - 4096 - 4352 - 4608 - 4864 - 5120 - 5376 - 5632 - 5888 - 6144
# --------------------------------------------------
default_num_ctx_for_host() {
  case "$1" in
    i7)  echo 2048 ;;
    e2m) echo 3096 ;;
    *)   echo 1024 ;;
  esac
}
NUM_CTX="${OLLAMA_NUM_CTX:-$(default_num_ctx_for_host "$HOST_SHORT")}"

TEMP_MIN="${SVN_AI_TEMP_MIN:-0.12}"
TEMP_MAX="${SVN_AI_TEMP_MAX:-0.28}"
TOP_P_MIN="${SVN_AI_TOP_P_MIN:-0.72}"
TOP_P_MAX="${SVN_AI_TOP_P_MAX:-0.90}"
REPEAT_MIN="${SVN_AI_REPEAT_MIN:-1.08}"
REPEAT_MAX="${SVN_AI_REPEAT_MAX:-1.18}"
MAX_ADDED_LINES="${SVN_AI_ADDED_LINES:-40}"
MAX_DIFF_LINES="${SVN_AI_DIFF_LINES:-80}"
MAX_BLOCK_CHARS="${SVN_AI_MAX_BLOCK_CHARS:-12000}"
DEBUG="${SVN_AI_DEBUG:-0}"

STATUS=""
CONTEXT_TERMS=""
TEMP="0.20"
TOP_P="0.80"
REPEAT="1.12"
PROFILE="balanced"
SEED=1303

usage() {
cat <<'EOF'
Usage:
  svn_ai_msg.sh [-p path] [-n level] [-s "suggestion"] [-d]
  svn_ai_msg.sh -h | --help


Options:
  -p PATH          Target SVN directory
  -n LEVEL         Creativity level (1–5)
  -s, --suggestion Provide commit suggestion text
  -d, --dry-run    Show commit without executing
  -h, --help       Show this help


Environment variables:

  OLLAMA_URL
      URL of the Ollama API endpoint
      Default: http://localhost:11434/api/generate

  OLLAMA_NUM_CTX
      Override maximum context size passed to the model
      Example: OLLAMA_NUM_CTX=2048

  SVN_AI_DEBUG
      Enable debug output (set to 1)
      Example: SVN_AI_DEBUG=1

  TEMP_MIN / TEMP_MAX
      Temperature range for generation

  TOP_P_MIN / TOP_P_MAX
      Top-p sampling range

  REPEAT_MIN / REPEAT_MAX
      Repeat penalty range

  MAX_ADDED_LINES
      Max lines used to summarize new files

  MAX_DIFF_LINES
      Max lines extracted from diffs

  MAX_BLOCK_CHARS
      Max characters sent to the model

Notes:
  - Environment variables override internal defaults
  - Useful for tuning performance and output style
EOF
}

error() { echo "Error: $*" >&2; exit 1; }
argument_error() { echo "Error: $*" >&2; echo >&2; usage >&2; exit 1; }
dbg() { [[ "$DEBUG" == "1" ]] && echo "DEBUG: $*" >&2; }

get_gpu_info() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | awk -F', ' '{printf("GPU: %s (used %s MiB / %s MiB)\n", $1, $2, $3)}'
  fi
}

get_ollama_processor() {
  if command -v ollama >/dev/null 2>&1; then
    echo "OLLAMA STATUS:"
    ollama ps 2>/dev/null || echo "  (no running model)"
    echo
  fi
}

print_debug_info() {
  {
    echo "HOST_SHORT: $HOST_SHORT"
    echo "TARGET: $TARGET"
    echo "MODEL: $MODEL"
    echo "NUM_CTX: $NUM_CTX"
    echo "CREATIVITY_LEVEL: $CREATIVITY_LEVEL"
    echo "DRY_RUN: $DRY_RUN"
    echo "COMMIT_SUGGESTION: $COMMIT_SUGGESTION"
    echo "COMMIT_GUIDANCE: $COMMIT_GUIDANCE"
    echo "TEMP_MIN: $TEMP_MIN"
    echo "TEMP_MAX: $TEMP_MAX"
    echo "TOP_P_MIN: $TOP_P_MIN"
    echo "TOP_P_MAX: $TOP_P_MAX"
    echo "REPEAT_MIN: $REPEAT_MIN"
    echo "REPEAT_MAX: $REPEAT_MAX"
    echo "MAX_ADDED_LINES: $MAX_ADDED_LINES"
    echo "MAX_DIFF_LINES: $MAX_DIFF_LINES"
    echo "MAX_BLOCK_CHARS: $MAX_BLOCK_CHARS"
    echo "GPU INFO:"
    get_gpu_info
    echo
    get_ollama_processor
  } >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) [[ $# -ge 2 ]] || argument_error "-p requires a path"; TARGET="$2"; shift 2 ;;
    -n) [[ $# -ge 2 ]] || argument_error "-n requires an integer from 1 to 5"; CREATIVITY_LEVEL="$2"; shift 2 ;;
    -n[1-5]) CREATIVITY_LEVEL="${1#-n}"; shift ;;
    -s|--suggestion|--hint) [[ $# -ge 2 ]] || argument_error "$1 requires suggestion text"; COMMIT_SUGGESTION="$2"; shift 2 ;;
    --suggestion=*|--hint=*) COMMIT_SUGGESTION="${1#*=}"; shift ;;
    -d|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) argument_error "unknown argument: $1" ;;
  esac
done
[[ "$CREATIVITY_LEVEL" =~ ^[1-5]$ ]] || argument_error "-n must be an integer from 1 to 5"

command -v svn >/dev/null 2>&1 || error "svn not found"
command -v python3 >/dev/null 2>&1 || error "python3 not found"
[[ -d "$TARGET" ]] || error "'$TARGET' is not a directory"
cd "$TARGET" || error "cannot enter '$TARGET'"
svn info . >/dev/null 2>&1 || error "'$TARGET' is not an SVN working copy"
STATUS="$(svn status . 2>/dev/null || true)"
[[ -n "${STATUS//[[:space:]]/}" ]] || error "no local SVN changes found"

# ---------- helpers ----------
has_commit_suggestion() { [[ -n "${COMMIT_SUGGESTION//[[:space:]]/}" ]]; }
has_commit_guidance()   { [[ -n "${COMMIT_GUIDANCE//[[:space:]]/}" ]]; }

clean_one_line() {
  local text="${1-}"
  python3 - "$text" <<'PY'
import sys,re
text=sys.argv[1]
line=''
for x in text.splitlines():
    x=x.strip()
    if x:
        line=x; break
line=re.sub(r'\s+',' ',line).strip().strip('"\'')
line=re.sub(r'^(commit message|message|output|result|note|explanation)\s*:\s*','',line,flags=re.I)
print(line[:120].rstrip(' ,;:.-'))
PY
}
normalize_line() { clean_one_line "$1"; }
clean_guidance_line() { clean_one_line "$1"; }

normalize_commit_verb() {
  local text="${1-}"
  python3 - "$text" <<'PY'
import sys,re
text=sys.argv[1].strip()
subs=[('adding','Add'),('added','Add'),('improving','Improve'),('improved','Improve'),('updating','Update'),('updated','Update'),('fixing','Fix'),('fixed','Fix'),('removing','Remove'),('removed','Remove'),('extending','Extend'),('extended','Extend'),('refactoring','Refactor'),('refactored','Refactor')]
out=text
for a,b in subs:
    out=re.sub(r'^'+a+r'\b', b, text, flags=re.I)
    if out!=text: break
print(out)
PY
}

humanize_filename() {
  local p="$1" b
  b="${p##*/}"
  b="${b%.*}"
  printf '%s\n' "$b" | tr '._-' '   ' | awk '{$1=$1; print}'
}

extract_paths_by_status() {
  local wanted="$1"
  printf '%s\n' "$STATUS" | awk -v st="$wanted" '$1 == st {print $2}'
}

linear_value() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
idx,total,vmin,vmax=int(sys.argv[1]),int(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
if total<=1: v=(vmin+vmax)/2
else: v=vmin+(vmax-vmin)*idx/(total-1)
print(f"{v:.4f}")
PY
}

profile_for_variant() {
  case "$1" in
    0) echo "very deterministic" ;;
    1) echo "conservative" ;;
    2) echo "balanced" ;;
    3) echo "slightly varied" ;;
    4) echo "more varied but technical" ;;
    *) echo "balanced" ;;
  esac
}

build_context_terms() {
  {
    printf '%s\n' "$STATUS" | awk '{print $2}'
    printf '%s\n' "$STATUS" | awk '{print $2}' | sed 's#.*/##' | sed 's/\..*$//' | tr '._-' '\n' | awk 'length($0)>2'
  } | awk 'NF' | sort -u | head -n 80
}

file_header_comments() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  head -n 40 "$f" 2>/dev/null | grep -E '^[[:space:]]*(#|//|/\*|\*|--|;)' | head -n 6
}
file_symbols() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -Eo '[A-Za-z_][A-Za-z0-9_]{2,}' "$f" 2>/dev/null | sort -u | head -n 30 | tr '\n' ' '
}
keywords_from_text() {
  grep -Eoi '[A-Za-z_][A-Za-z0-9_]{2,}' | sort -u | head -n 30 | tr '\n' ' '
}
compact_diff_for_file() {
  local f="$1"
  svn diff -- "$f" 2>/dev/null | awk '/^@@ / || /^[+-][^+-]/ {print}' | head -n "$MAX_DIFF_LINES" | python3 - "$MAX_BLOCK_CHARS" <<'PY'
import sys
n=int(sys.argv[1]); data=sys.stdin.read(); print(data[:n], end='')
PY
}
added_preview_for_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  head -n "$MAX_ADDED_LINES" "$f" 2>/dev/null | python3 - "$MAX_BLOCK_CHARS" <<'PY'
import sys
n=int(sys.argv[1]); data=sys.stdin.read(); print(data[:n], end='')
PY
}

run_model() {
  local prompt="$1" temp="${2:-$TEMP}" top_p="${3:-$TOP_P}" repeat_penalty="${4:-$REPEAT}" num_predict="${5:-80}" seed="${6:-$SEED}"
  if ! command -v ollama >/dev/null 2>&1; then printf '\n'; return 0; fi
  local prompt_file
  prompt_file="$(mktemp)" || return 0
  printf '%s' "$prompt" > "$prompt_file"
  python3 - "$OLLAMA_URL" "$MODEL" "$prompt_file" "$temp" "$top_p" "$repeat_penalty" "$NUM_CTX" "$num_predict" "$seed" <<'PY'
import sys,json,urllib.request
url,model,prompt_file,temperature,top_p,repeat_penalty,num_ctx,num_predict,seed=sys.argv[1:10]
prompt=open(prompt_file,'r',encoding='utf-8',errors='replace').read()
payload={'model':model,'prompt':prompt,'stream':False,'options':{'temperature':float(temperature),'top_p':float(top_p),'repeat_penalty':float(repeat_penalty),'num_ctx':int(float(num_ctx)),'num_predict':int(float(num_predict)),'seed':int(float(seed))}}
req=urllib.request.Request(url,data=json.dumps(payload).encode('utf-8'),headers={'Content-Type':'application/json'})
try:
    with urllib.request.urlopen(req,timeout=300) as resp:
        raw=resp.read().decode('utf-8',errors='replace')
        obj=json.loads(raw)
        print(obj.get('response',''))
except Exception:
    print('')
PY
  local rc=$?
  rm -f "$prompt_file"
  return "$rc"
}

build_suggestion_interpretation_prompt() {
  local suggestion="$1" status_block="$2" context_terms="$3"
  cat <<EOF
Interpret the user's suggestion as one English guidance sentence for commit-message generation.
Rules:
- Output exactly one English sentence
- Max 180 characters
- Do not write the final commit message
- Keep the guidance subordinate to the actual diff
SVN status:
$status_block
Context terms:
$context_terms
User suggestion:
$suggestion
Output:
EOF
}

deterministic_guidance_from_suggestion() {
  local suggestion="$1" low
  low="$(printf '%s' "$suggestion" | tr '[:upper:]' '[:lower:]')"
  if [[ "$low" == *"suggest"* || "$low" == *"guidance"* || "$low" == *"hint"* ]]; then
    echo "Emphasize user guidance in commit message generation when supported by the diff"
  else
    echo "Prefer the main user-visible change while keeping the message grounded in the SVN diff"
  fi
}

interpret_commit_suggestion() {
  local suggestion="$1" prompt raw guidance
  prompt="$(wrap_strict_context "$(build_suggestion_interpretation_prompt "$suggestion" "$STATUS" "$CONTEXT_TERMS")")"
  raw="$(run_model "$prompt" "$TEMP" "$TOP_P" "$REPEAT" 64 "$((SEED + 17))")"
  guidance="$(clean_guidance_line "$raw")"
  if [[ -z "${guidance//[[:space:]]/}" ]]; then
    guidance="$(deterministic_guidance_from_suggestion "$suggestion")"
  fi
  printf '%s\n' "$guidance"
}

prompt_user_suggestion_block() {
  if has_commit_guidance; then
    cat <<EOF
High-priority interpreted user guidance:
$COMMIT_GUIDANCE
EOF
  fi
}

wrap_strict_context() {
  local body="$1"

  cat <<EOF
### CONTEXT START
You are a stateless assistant.

You MUST ONLY use information inside INPUT_START and INPUT_END.
You MUST ignore any prior knowledge or memory.

If a concept is not explicitly present in the input, DO NOT mention it.

### INPUT START
$body
### INPUT END

### TASK
Generate a commit message using ONLY the input above.

Rules:
- Use only concepts from the input
- Do not introduce external tools, names, or technologies
- Do not hallucinate or guess context
- Output one short English sentence

### OUTPUT
EOF
}

build_added_prompt() {
  local f="$1" profile="$2" preview="$3" header="$4" symbols="$5" keywords="$6"

  local core
  core=$(cat <<EOF
Task: Describe the purpose of this NEW file.

Rules:
- Output one short English phrase
- Max 60 characters
- Start with Add or Introduce
- No explanations
- Prefer "check", "report", or "status" wording if applicable

File: $(basename "$f")
Filename meaning: $(humanize_filename "$f")
Header comments: $header
Symbols: $symbols
Keywords: $keywords
Preview:
$preview
EOF
)

  wrap_strict_context "$core"
}



build_modified_prompt() {
  local f="$1" profile="$2" diff="$3" header="$4" symbols="$5" keywords="$6"

  local core
  core=$(cat <<EOF
Task: Describe the OVERALL change in this MODIFIED file.

Rules:
- Output one short English phrase
- Max 90 characters
- Start with Add, Improve, Fix, Refactor, Update, Remove, or Extend
- Do not invent changes not present in the diff
- No explanations

File: $(basename "$f")
Filename meaning: $(humanize_filename "$f")
Header comments: $header
Symbols: $symbols
Keywords: $keywords
Diff:
$diff
EOF
)

  wrap_strict_context "$core"
}


build_deleted_prompt() {
  local f="$1"
  cat <<EOF
You write SVN commit message fragments.
Task: Describe this deleted file.
Rules:
- Output one short English phrase
- Max 50 characters
- Start with Remove
Deleted file: $(basename "$f")
Output:
EOF
}

diff_mentions_suggestion_feature() {
  local diff="$1" low
  low="$(printf '%s' "$diff" | tr '[:upper:]' '[:lower:]')"
  [[ "$low" == *"commit_suggestion"* || "$low" == *"commit_guidance"* || "$low" == *"--suggestion"* || "$low" == *"--hint"* || "$low" == *"svn_ai_suggestion"* || "$low" == *"guidance"* ]]
}

rule_based_modified_description() {
  local f="$1" diff="$2" low full_diff full_low
  low="$(printf '%s' "$diff" | tr '[:upper:]' '[:lower:]')"

  # Use the full SVN diff for semantic rule detection.
  # The compact diff may truncate exactly the helper/function names we need.
  full_diff="$(svn diff -- "$f" 2>/dev/null || true)"
  full_low="$(printf '%s' "$full_diff" | tr '[:upper:]' '[:lower:]')"

  if [[ "$full_low" == *"candidate_score"* || "$full_low" == *"is_bad_llm_description"* || "$full_low" == *"shuffle_join"* || "$full_low" == *"join_parts"* || "$full_low" == *"count_summary"* || "$full_low" == *"first_non_empty"* ]]; then
    echo "Restore helper functions for commit message generation"
  elif [[ "$full_low" == *"commit_guidance"* || "$full_low" == *"commit_suggestion"* || "$full_low" == *"--suggestion"* || "$full_low" == *"--hint"* ]]; then
    echo "Add user guidance support to commit message generation"
  elif [[ "$low" == *"dry-run"* || "$low" == *"--dry-run"* ]]; then
    echo "Improve dry-run commit workflow and output"
  elif [[ "$low" == *"usage"* || "$low" == *"--help"* || "$low" == *"argument_error"* ]]; then
    echo "Improve CLI usage, validation, and help output"
  elif [[ "$low" == *"summary"* || "$low" == *"suggested messages"* || "$low" == *"file change summary"* ]]; then
    echo "Improve file summary and commit candidate generation"
  elif [[ "$low" == *"fallback"* || "$low" == *"candidate"* || "$low" == *"mode"* ]]; then
    echo "Refactor commit candidate selection and fallback handling"
  elif [[ "$low" == *":-"* || "$low" == *"set -u"* || "$low" == *"unbound"* || "$low" == *"default"* ]]; then
    echo "Fix shell variable defaults and safer option handling"
  elif [[ "$low" == *"urllib.request"* || "$low" == *"json.dumps"* || "$low" == *"timeout"* ]]; then
    echo "Improve Ollama request handling and robustness"
  elif [[ "$low" == *"candidate_score"* || "$low" == *"is_bad_llm_description"* || "$low" == *"shuffle_join"* || "$low" == *"join_parts"* || "$low" == *"count_summary"* || "$low" == *"first_non_empty"* ]]; then
    echo "Restore helper functions for commit message generation"
  elif [[ "$f" == *.sh ]]; then
    echo "Improve SVN commit message generation"
  else
    echo "Update $(basename "$f")"
  fi
}

merge_modified_descriptions() {
  local rule_hint="$1" llm_desc="$2"
  if is_bad_llm_description "$llm_desc"; then
    echo "$rule_hint"
    return
  fi
  if [[ -z "${llm_desc//[[:space:]]/}" ]]; then
    echo "$rule_hint"
    return
  fi
  local cleaned
  cleaned="$(normalize_line "$llm_desc")"
  cleaned="$(normalize_commit_verb "$cleaned")"
  if [[ -z "${cleaned//[[:space:]]/}" ]]; then
    echo "$rule_hint"
    return
  fi

  local cleaned_lc
  cleaned_lc="$(printf '%s' "$cleaned" | tr '[:upper:]' '[:lower:]')"

  if [[ "$cleaned_lc" == *"readability"* || "$cleaned_lc" == *"maintainability"* || "$cleaned_lc" == *"refactor code"* || "$cleaned_lc" == *"refactor file"* ]]; then
    echo "$rule_hint"
    return
  fi

  echo "$cleaned"
}

join_parts() {
  local out="" first=1 x
  for x in "$@"; do
    [[ -n "${x//[[:space:]]/}" ]] || continue
    if (( first )); then out="$x"; first=0; else out="$out; $x"; fi
  done
  printf '%s\n' "$out"
}

first_non_empty() {
  local x
  for x in "$@"; do
    if [[ -n "${x//[[:space:]]/}" ]]; then printf '%s\n' "$x"; return 0; fi
  done
  printf '\n'
}

count_summary() {
  local added_count="$1" modified_count="$2" deleted_count="$3"
  local parts=()
  (( added_count > 0 )) && parts+=("$added_count added")
  (( modified_count > 0 )) && parts+=("$modified_count modified")
  (( deleted_count > 0 )) && parts+=("$deleted_count deleted")
  if ((${#parts[@]} == 0)); then echo "project"; else printf '%s' "${parts[*]}"; fi
}


dedup_descriptions() {
  # remove duplicates while preserving order
  python3 - <<'PY_DEDUP'
import sys

seen = set()
out = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line not in seen:
        seen.add(line)
        out.append(line)

print("; ".join(out))
PY_DEDUP
}

shuffle_join() {
  python3 - <<'PY'
import sys, random
items=[x.strip() for x in sys.stdin if x.strip()]
random.seed(1337)
random.shuffle(items)
print('; '.join(items[:3]))
PY
}

best_semantic_description() {
  local best="" best_score=-999999 x score
  for x in "${MOD_DESC[@]}" "${ADDED_DESC[@]}" "${DEL_DESC[@]}"; do
    [[ -n "${x//[[:space:]]/}" ]] || continue
    score="$(candidate_score "$x")"
    dbg "candidate_score=$score text=$x"
    if (( score > best_score )); then best_score=$score; best="$x"; fi
  done
  dbg "best_semantic_description=$best score=$best_score"
  printf '%s\n' "$best"
}

fallback_message() {
  local added_count="$1" modified_count="$2" deleted_count="$3" best
  best="$(best_semantic_description)"
  if [[ -n "${best//[[:space:]]/}" ]]; then printf '%s\n' "$best"; else echo "Update $(count_summary "$added_count" "$modified_count" "$deleted_count") file(s)"; fi
}

make_perfile_description() { join_parts "${SUMMARY_ADDED[@]}" "${SUMMARY_MODIFIED[@]}" "${SUMMARY_DELETED[@]}"; }
make_full_description() {
  if [[ -n "${ALL_DESCRIPTIONS//[[:space:]]/}" ]]; then printf '%s\n' "$ALL_DESCRIPTIONS"; else fallback_message "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}"; fi
}
make_compact_description() {
  local best
  best="$(best_semantic_description)"
  if [[ -n "${best//[[:space:]]/}" ]]; then printf '%s\n' "$best"; else join_parts "$FIRST_MOD" "$FIRST_ADD" "$FIRST_DEL"; fi
}
make_technical_description() {
  local candidate
  candidate="$(first_non_empty "$MOD_DESCRIPTIONS_ONLY" "$ALL_DESCRIPTIONS")"
  if [[ -n "${candidate//[[:space:]]/}" ]]; then printf '%s\n' "$candidate"; else fallback_message "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}"; fi
}
make_shuffle_description() {
  if [[ -n "${ALL_DESCRIPTIONS//[[:space:]]/}" ]]; then printf '%s\n' "$ALL_DESCRIPTIONS" | tr ';' '\n' | shuffle_join; else fallback_message "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}"; fi
}

shell_quote() { python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]), end="")' "$1"; }

ask_commit_with_selected_message() {
  local total="$1"
  [[ -e /dev/tty ]] || return 0
  echo > /dev/tty
  printf 'Select a candidate number to commit (1-%s), or press Enter to skip: ' "$total" > /dev/tty
  local answer=""
  IFS= read -r answer < /dev/tty || return 0
  [[ -z "${answer//[[:space:]]/}" ]] && return 0
  [[ "$answer" =~ ^[0-9]+$ ]] || { echo "Invalid selection." > /dev/tty; return 0; }
  (( answer >= 1 && answer <= total )) || { echo "Selection out of range." > /dev/tty; return 0; }
  local msg="${FINAL_COMMENTS[$((answer-1))]}"
  if (( DRY_RUN )); then
    echo > /dev/tty
    echo "Dry run command:" > /dev/tty
    echo "svn commit -m $(shell_quote "$msg")" > /dev/tty
    return 0
  fi
  echo > /dev/tty
  echo "Running: svn commit -m $(shell_quote "$msg")" > /dev/tty
  svn commit -m "$msg"
}

build_variant() {
  local mode="$1" result=""
  case "$mode" in
    perfile)   result="$(make_perfile_description)" ;;
    full)      result="$(make_full_description)" ;;
    compact)   result="$(make_compact_description)" ;;
    minimal)   result="Update $(count_summary "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}") file(s)" ;;
    technical) result="$(make_technical_description)" ;;
    shuffle)   result="$(make_shuffle_description)" ;;
    *)         result="$(fallback_message "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}")" ;;
  esac
  result="$(normalize_line "$result")"
  result="$(normalize_commit_verb "$result")"
  dbg "mode=$mode result=$result"
  printf '%s\n' "$result"
}

# --- HOTFIX: missing helper functions ---

is_bad_llm_description() {
  local text="${1-}"
  [[ -z "${text//[[:space:]]/}" ]] && return 0

  local lc
  lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

  [[ "$lc" == *"based on the provided text"* ]] && return 0
  [[ "$lc" == *"here are some suggestions"* ]] && return 0
  [[ "$lc" == *"provided text"* ]] && return 0
  [[ "$lc" == *"this script"* ]] && return 0
  [[ "$lc" == *"the script"* ]] && return 0
  [[ "$lc" == *"looks like"* ]] && return 0
  [[ "$lc" == *"output:"* ]] && return 0
  [[ "$lc" == *"result:"* ]] && return 0

  return 1
}


candidate_score() {
  local text="${1-}"
  python3 - "$text" <<'PY_SCORE'
import sys, re

text = sys.argv[1].strip()
if not text:
    print(-999)
    raise SystemExit(0)

low = text.lower()
score = 0

if re.match(r'^(add|improve|update|fix|refactor|remove|extend|introduce)\b', low):
    score += 25

for kw in [
    'guidance', 'suggestion', 'commit message', 'generation',
    'candidate', 'summary', 'output', 'validation', 'usage',
    'workflow', 'fallback', 'selection', 'parsing', 'defaults',
    'request', 'ollama', 'dry-run', 'dry run', 'error handling',
    'help'
]:
    if kw in low:
        score += 7

n = len(text)
if 28 <= n <= 95:
    score += 18
elif 20 <= n <= 120:
    score += 10
elif n < 12:
    score -= 20
else:
    score -= 6

for bad in [
    'project files',
    'modified file(s)',
    'update file',
    'update files',
    'file(s)',
    'improve code',
    'change things',
    'various fixes',
    'user experience',
    'reduce complexity',
    'improve complexity',
    'improve maintainability',
    'improve readability',
    'overall improvements',
    'general cleanup',
    'cleanup',
    'simplify code',
    'simplification'
]:
    if bad in low:
        score -= 24

for bad in [
    'based on',
    'here are',
    'provided text',
    'this script',
    'the script',
    'output:',
    'result:'
]:
    if bad in low:
        score -= 100

score -= max(0, text.count(';') - 1) * 4
print(score)
PY_SCORE
}

# --- END HOTFIX ---


CREATIVITY_STEPS=5
CREATIVITY_INDEX=$((CREATIVITY_LEVEL - 1))
TEMP="$(linear_value "$CREATIVITY_INDEX" "$CREATIVITY_STEPS" "$TEMP_MIN" "$TEMP_MAX")"
TOP_P="$(linear_value "$CREATIVITY_INDEX" "$CREATIVITY_STEPS" "$TOP_P_MIN" "$TOP_P_MAX")"
REPEAT="$(linear_value "$CREATIVITY_INDEX" "$CREATIVITY_STEPS" "$REPEAT_MAX" "$REPEAT_MIN")"
PROFILE="$(profile_for_variant "$CREATIVITY_INDEX")"
SEED="$((1000 + CREATIVITY_LEVEL * 101))"
[[ "$DEBUG" == "1" ]] && print_debug_info

mapfile -t FILES_ADDED < <(extract_paths_by_status "A")
mapfile -t FILES_MODIFIED < <(extract_paths_by_status "M")
mapfile -t FILES_DELETED < <(extract_paths_by_status "D")
CONTEXT_TERMS="$(build_context_terms | tr '\n' ' ')"

if has_commit_suggestion; then
  COMMIT_GUIDANCE="$(interpret_commit_suggestion "$COMMIT_SUGGESTION")"
fi

MODES=(perfile full compact minimal technical shuffle)
ADDED_DESC=()
MOD_DESC=()
DEL_DESC=()
SUMMARY_ADDED=()
SUMMARY_MODIFIED=()
SUMMARY_DELETED=()
FINAL_COMMENTS=()
FINAL_MODES=()

for f in "${FILES_ADDED[@]}"; do
  [[ -f "$f" ]] || continue
  preview="$(added_preview_for_file "$f")"
  header="$(file_header_comments "$f")"
  symbols="$(file_symbols "$f")"
  keywords="$(printf '%s\n%s\n%s' "$preview" "$header" "$symbols" | keywords_from_text)"
  prompt="$(build_added_prompt "$f" "$PROFILE" "$preview" "$header" "$symbols" "$keywords")"
  raw="$(run_model "$prompt" "$TEMP" "$TOP_P" "$REPEAT" 48 "$((SEED + 11))")"
  out="$(clean_one_line "$raw")"
  [[ -n "${out//[[:space:]]/}" ]] || out="Add $(humanize_filename "$f")"
  out="$(normalize_commit_verb "$out")"

  # Avoid misleading descriptions for read-only Unison checker scripts.
  out_lc="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  preview_lc="$(printf '%s' "$preview" | tr '[:upper:]' '[:lower:]')"
  if [[ "$f" == *"unison_check_sync.sh"* && "$out_lc" == *"synchronizing files"* ]]; then
    out="Add read-only Unison profile sync checker"
  elif [[ "$preview_lc" == *"non sincronizza"* && "$out_lc" == *"synchronizing"* ]]; then
    out="$(printf '%s' "$out" | sed -E 's/for checking and synchronizing files/to check sync status/I')"
  fi

  ADDED_DESC+=("$out")
  SUMMARY_ADDED+=("$(basename "$f"): $out")
done

for f in "${FILES_MODIFIED[@]}"; do
  [[ -e "$f" ]] || continue
  diff="$(compact_diff_for_file "$f")"
  header="$(file_header_comments "$f")"
  symbols="$(file_symbols "$f")"
  keywords="$(printf '%s\n%s\n%s' "$diff" "$header" "$symbols" | keywords_from_text)"
  rule_hint="$(rule_based_modified_description "$f" "$diff")"
  prompt="$(build_modified_prompt "$f" "$PROFILE" "$diff" "$header" "$symbols" "$keywords")"
  raw="$(run_model "$prompt" "$TEMP" "$TOP_P" "$REPEAT" 64 "$((SEED + 21))")"
  llm_desc="$(clean_one_line "$raw")"
  out="$(merge_modified_descriptions "$rule_hint" "$llm_desc")"
  [[ -n "${out//[[:space:]]/}" ]] || out="$rule_hint"
  MOD_DESC+=("$out")
  SUMMARY_MODIFIED+=("$(basename "$f"): $out")
done

for f in "${FILES_DELETED[@]}"; do
  prompt="$(build_deleted_prompt "$f")"
  raw="$(run_model "$prompt" "$TEMP" "$TOP_P" "$REPEAT" 32 "$((SEED + 31))")"
  out="$(clean_one_line "$raw")"
  [[ -n "${out//[[:space:]]/}" ]] || out="Remove $(humanize_filename "$f")"
  out="$(normalize_commit_verb "$out")"
  DEL_DESC+=("$out")
  SUMMARY_DELETED+=("$(basename "$f"): $out")
done

FIRST_MOD=""; FIRST_ADD=""; FIRST_DEL=""
[[ ${#MOD_DESC[@]} -gt 0 ]] && FIRST_MOD="${MOD_DESC[0]}"
[[ ${#ADDED_DESC[@]} -gt 0 ]] && FIRST_ADD="${ADDED_DESC[0]}"
[[ ${#DEL_DESC[@]} -gt 0 ]] && FIRST_DEL="${DEL_DESC[0]}"


ADDED_CANDIDATES=()
MODIFIED_CANDIDATES=()
ALL_DESCRIPTIONS="$(join_parts "${ADDED_DESC[@]}" "${MOD_DESC[@]}" "${DEL_DESC[@]}")"
MOD_DESCRIPTIONS_ONLY="$(join_parts "${MOD_DESC[@]}")"

dbg "SUMMARY_MODIFIED count=${#SUMMARY_MODIFIED[@]} value=$(join_parts "${SUMMARY_MODIFIED[@]}")"
dbg "ALL_DESCRIPTIONS=$ALL_DESCRIPTIONS"
dbg "MOD_DESCRIPTIONS_ONLY=$MOD_DESCRIPTIONS_ONLY"

for mode in "${MODES[@]}"; do
  c="$(build_variant "$mode")"
  [[ -n "${c//[[:space:]]/}" ]] || c="$(fallback_message "${#FILES_ADDED[@]}" "${#FILES_MODIFIED[@]}" "${#FILES_DELETED[@]}")"
  FINAL_MODES+=("$mode")
  FINAL_COMMENTS+=("$c")
done

if has_commit_suggestion; then
  echo "User suggestion: $COMMIT_SUGGESTION"
  if has_commit_guidance; then
    echo "Interpreted guidance: $COMMIT_GUIDANCE"
  fi
  echo
fi

echo "==================================="
echo "      FILE CHANGE SUMMARY"
echo "==================================="
if (( ${#SUMMARY_ADDED[@]} == 0 && ${#SUMMARY_MODIFIED[@]} == 0 && ${#SUMMARY_DELETED[@]} == 0 )); then
  echo "No per-file descriptions generated."
fi
for line in "${SUMMARY_ADDED[@]}"; do echo "[A] $line"; done
for line in "${SUMMARY_MODIFIED[@]}"; do echo "[M] $line"; done
for line in "${SUMMARY_DELETED[@]}"; do echo "[D] $line"; done

echo "==================================="
echo "      SUGGESTED MESSAGES"
echo "==================================="
for i in "${!FINAL_COMMENTS[@]}"; do
  echo "[$((i + 1))] (${FINAL_MODES[$i]}) ${FINAL_COMMENTS[$i]}"
done

ask_commit_with_selected_message "${#FINAL_COMMENTS[@]}"
