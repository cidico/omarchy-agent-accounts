#!/usr/bin/env bash
# Claude Code status line: folder, git, model+effort, context, 5h window, weekly usage
input=$(cat)
j() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }
# Account of the running session: a second account runs with CLAUDE_CONFIG_DIR=~/.claude-<name>, the default uses ~/.claude
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}; acct=$(basename "$cfg"); acct=${acct#.}

cwd=$(j '.workspace.current_dir'); [ -z "$cwd" ] && cwd=$(j '.cwd')
model=$(j '.model.display_name')
effort=$(j '.effort.level'); [ -z "$effort" ] && effort=$(j '.effort')
[ -z "$effort" ] && effort=$(jq -r '.effortLevel // empty' "$cfg/settings.json" 2>/dev/null)
ctx=$(j '.context_window.used_percentage')
cost=$(j '.cost.total_cost_usd')
perm=$(j '.permission_mode'); [ -z "$perm" ] && perm=$(j '.permissionMode')
[ -z "$perm" ] && perm=$(jq -r '.permissions.defaultMode // empty' "$cfg/settings.json" 2>/dev/null)
wt=$(j '.worktree.name'); [ -z "$wt" ] && wt=$(j '.workspace.git_worktree')
h5=$(j '.rate_limits.five_hour.used_percentage'); h5r=$(j '.rate_limits.five_hour.resets_at')
d7=$(j '.rate_limits.seven_day.used_percentage'); d7r=$(j '.rate_limits.seven_day.resets_at')

# Fable weekly limit: not in the stdin JSON, so read it from the account usage endpoint (cached 30 min per account)
# One fetch at a time per account (the lock is shared with the Agent Accounts bar widget), and a failed fetch
# backs off instead of retrying on every 10s refresh: 60s, doubling on each 429 up to 10 min.
usage_cache=~/.cache/claude-statusline-usage-$acct.json
usage_lock=~/.cache/claude-statusline-usage-$acct.lock
usage_attempt=~/.cache/claude-statusline-usage-$acct.attempt
usage_due() {
  local now at bo; now=$(date +%s)
  [ -f "$usage_cache" ] && [ $(( now - $(stat -c %Y "$usage_cache") )) -le 1800 ] && return 1
  if [ -f "$usage_attempt" ]; then read -r at bo < "$usage_attempt"; [ $(( now - ${at:-0} )) -lt "${bo:-60}" ] && return 1; fi
  return 0
}
fetch_usage() {
  local tok code at bo tmp="$usage_cache.tmp.$$"; tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$cfg/.credentials.json" 2>/dev/null)
  [ -z "$tok" ] && return
  mkdir -p ~/.cache
  code=$(curl -s -m 3 -o "$tmp" -w '%{http_code}' https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" -H "User-Agent: claude-code")
  if [ "$code" = 200 ] && jq -e '.limits' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$usage_cache" && log_usage
    rm -f "$usage_attempt"
  else
    bo=60
    if [ "$code" = 429 ] && [ -f "$usage_attempt" ]; then
      read -r at bo < "$usage_attempt"; bo=$(( ${bo:-30} * 2 )); [ "$bo" -lt 60 ] && bo=60; [ "$bo" -gt 600 ] && bo=600
    fi
    printf '%s %s\n' "$(date +%s)" "$bo" > "$usage_attempt"
  fi
  rm -f "$tmp"
}
# Usage history per account: one row whenever a percentage changes (compared against transcripts later)
usage_log=~/.local/state/claude-usage-$acct.tsv
log_usage() {
  local row; row=$(jq -r '[
      (.limits[] | select(.kind=="session") | .percent) // "",
      (.limits[] | select(.kind=="weekly_all") | .percent) // "",
      ([.limits[] | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable")][0].percent) // "",
      (.limits[] | select(.kind=="weekly_all") | .resets_at[0:16]) // ""] | @tsv' "$usage_cache" 2>/dev/null) || return
  [ -f "$usage_log" ] || printf 'time\tsession_pct\tweekly_pct\tfable_weekly_pct\tweekly_resets_at\n' > "$usage_log"
  [ "$(tail -n1 "$usage_log" | cut -f2-)" = "$row" ] || printf '%s\t%s\n' "$(date -Is)" "$row" >> "$usage_log"
}
if usage_due; then
  ( flock -n 9 || exit 0; usage_due && fetch_usage ) 9>"$usage_lock"
fi
fb=$(jq -r '[.limits[]? | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable")][0] | "\(.percent // "") \(.resets_at // "")"' "$usage_cache" 2>/dev/null)
fbp=${fb%% *}; fbr=""
[ -n "${fb#* }" ] && [ "${fb#* }" != "$fb" ] && fbr=$(date -d "${fb#* }" +%s 2>/dev/null)

R=$'\e[0m'; DIM=$'\e[2m'; CY=$'\e[36m'; BCY=$'\e[1;36m'; ICY=$'\e[3;36m'
GRN=$'\e[32m'; YEL=$'\e[33m'; RED=$'\e[31m'

color() { local p=${1%.*}; if [ "$p" -ge 85 ]; then printf %s "$RED"; elif [ "$p" -ge 60 ]; then printf %s "$YEL"; else printf %s "$GRN"; fi; }
bar() { local p=${1%.*} w=8 f i s=""; f=$(( (p*w+50)/100 )); [ $f -gt $w ] && f=$w
  for ((i=0;i<w;i++)); do [ $i -lt $f ] && s+="█" || s+="░"; done; printf %s "$s"; }
until_reset() { local t=$(( $1 - $(date +%s) )); [ $t -le 0 ] && { printf now; return; }
  local d=$((t/86400)) h=$(( (t%86400)/3600 )) m=$(( (t%3600)/60 ))
  if [ $d -gt 0 ]; then printf '%dd %dh' $d $h; elif [ $h -gt 0 ]; then printf '%dh %02dm' $h $m; else printf '%dm' $m; fi; }
meter() { # label pct resets_at
  [ -z "$2" ] && return
  printf ' %s│%s %s%s %s%s %s%.0f%%%s' "$DIM" "$R" "$DIM$1$R" "" "$(color "$2")" "$(bar "$2")" "$(color "$2")" "$2" "$R"
  [ -n "$3" ] && printf '%s reseta em %s%s' "$DIM" "$(until_reset "$3")" "$R"; }

# model + effort
printf '%s%s%s' "$BCY" "${model:-?}" "$R"
[ -n "$effort" ] && printf ' %s%s%s' "$ICY" "$effort" "$R"

# folder + git
printf ' %s│%s ' "$DIM" "$R"
g() { git -C "$cwd" --no-optional-locks "$@" 2>/dev/null; }
root=$(g rev-parse --show-toplevel)
if [ -n "$root" ]; then
  rel="${cwd#$root}"; rel="${rel#/}"
  printf '%s%s%s' "$BCY" "$(basename "$root")" "$R"; [ -n "$rel" ] && printf '%s/%s%s' "$CY" "$rel" "$R"
  if [ -z "$wt" ] && [ "$(g rev-parse --git-dir)" != "$(g rev-parse --git-common-dir)" ]; then wt=$(basename "$root"); fi
  b=$(g symbolic-ref --short HEAD || g rev-parse --short HEAD); printf ' %s%s%s' "$ICY" "$b" "$R"
  [ -n "$wt" ] && printf ' %s⎇ %s%s' "$YEL" "$wt" "$R"
  s=""; c=$(g rev-list --left-right --count '@{upstream}...HEAD')
  if [ -n "$c" ]; then bh=${c%%[[:space:]]*}; ah=${c##*[[:space:]]}
    [ "$ah" -gt 0 ] && s+="⇡$ah"; [ "$bh" -gt 0 ] && s+="⇣$bh"; fi
  n=$(g status --porcelain | wc -l); [ "$n" -gt 0 ] && s+=" ±$n"
  [ -n "$s" ] && printf ' %s%s%s' "$CY" "$s" "$R"
else
  printf '%s%s%s' "$CY" "${cwd/#$HOME/~}" "$R"
fi

[ -n "$perm" ] && [ "$perm" != "default" ] && printf ' %s(%s)%s' "$DIM" "$perm" "$R"

if [ -n "$ctx" ]; then
  ci=${ctx%.*}
  if [ "$ci" -ge 80 ]; then printf ' %s│%s %s\e[1m⚠ ctx %s%% — /compact%s' "$DIM" "$R" "$RED" "$ci" "$R"
  else printf ' %s│%s %sctx%s %s%s%%%s' "$DIM" "$R" "$DIM" "$R" "$(color "$ctx")" "$ci" "$R"; fi
fi
meter "5h" "$h5" "$h5r"
meter "7d" "$d7" "$d7r"
meter "Fable 7d" "$fbp" "$fbr"
[ -n "$cost" ] && printf ' %s│%s %s$%.2f%s' "$DIM" "$R" "$CY" "$cost" "$R"
echo
