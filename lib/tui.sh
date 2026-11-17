#!/usr/bin/env bash
# Full-screen TUI for zapret-arch. Sourced by the CLI; no external deps.

TUI_LOG=${STATE_DIR:?STATE_DIR must be set}/last-action.log
TUI_ACTIVE=0
TUI_SELECTED=0
TUI_TOP=0
TUI_FLASH=""
TUI_FLASH_KIND=info
TUI_CURRENT=""
TUI_GAMES=off
TUI_VOICE=on
TUI_MC=off
TUI_BOOT=disabled
TUI_DETAIL_W=40
TUI_STATUS_TEXT=""
TUI_STATUS_COLOR=""
declare -a TUI_NAMES=()
declare -a TUI_DETAIL=()
declare -A TUI_RESULTS=()

tui_at() { printf '\033[%d;%dH' "$1" "$2"; }

tui_cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( TUI_ACTIVE )); then
    tput sgr0 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    printf '\033]0;zapret\007'
    TUI_ACTIVE=0
  fi
  exit "$rc"
}

tui_enter_screen() {
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  TUI_ACTIVE=1
  printf '\033]0;zapret\007'
}

tui_leave_screen() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  TUI_ACTIVE=0
}

tui_color_init() {
  C_RESET='' C_BOLD='' C_DIM='' C_ACC='' C_OK='' C_WARN='' C_FAIL='' C_REV=''
  if [[ -n ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_REV=$'\033[7m'
    return
  fi
  local colors=0
  if command -v tput >/dev/null; then
    colors=$(tput colors 2>/dev/null || echo 0)
  fi
  case $colors in
    ''|*[!0-9-]*) colors=0 ;;
  esac
  if (( colors >= 256 )); then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_REV=$'\033[7m'
    C_DIM=$'\033[38;5;244m' C_ACC=$'\033[38;5;45m'
    C_OK=$'\033[38;5;78m' C_WARN=$'\033[38;5;214m' C_FAIL=$'\033[38;5;203m'
  elif (( colors >= 16 )); then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_REV=$'\033[7m'
    C_DIM=$'\033[90m' C_ACC=$'\033[36m'
    C_OK=$'\033[32m' C_WARN=$'\033[33m' C_FAIL=$'\033[31m'
  else
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_REV=$'\033[7m'
  fi
}

tui_set_symbols() {
  if tui_utf8; then
    S_BAR='▌' S_DOT='●' S_STOP='○' S_OK='✓' S_FAIL='✗' S_NONE='—' S_ELL='…' S_MID='·'
    S_V='│' S_H='─' S_UP='↑' S_DOWN='↓'
  else
    S_BAR='>' S_DOT='*' S_STOP='o' S_OK='OK' S_FAIL='!!' S_NONE='-' S_ELL='...' S_MID='-'
    S_V='|' S_H='-' S_UP='^' S_DOWN='v'
  fi
}

tui_utf8() {
  [[ ${ZAPRET_ASCII:-0} != 1 ]] || return 1
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  [[ $loc == *[Uu][Tt][Ff]-8* || $loc == *[Uu][Tt][Ff]8* ]]
}

tui_cols() {
  local n
  n=$(tput cols 2>/dev/null || echo 80)
  [[ $n =~ ^[0-9]+$ ]] || n=80
  echo "$n"
}

tui_rows() {
  local n
  n=$(tput lines 2>/dev/null || echo 24)
  [[ $n =~ ^[0-9]+$ ]] || n=24
  echo "$n"
}

tui_trim() {
  local s=$1 w=$2
  if (( w <= 0 )); then
    return 0
  elif (( ${#s} > w )); then
    if (( w > 1 )); then printf '%s%s' "${s:0:w-1}" "$S_ELL"; else printf '%s' "${s:0:w}"; fi
  else
    printf '%s' "$s"
  fi
}


tui_hline() {
  local w=$1 line
  (( w > 0 )) || return 0
  printf -v line '%*s' "$w" ''
  line=${line// /$S_H}
  printf '%s' "$line"
}

tui_wrap() {
  local text=$1 width=$2 limit=${3:-4}
  (( width > 4 )) || width=4
  fold -w "$width" <<<"$text" | sed -n "1,${limit}p"
}

tui_reload() {
  TUI_NAMES=()
  local file name score
  local -a names=()
  for file in "$PROFILES_DIR"/*.opt; do
    [[ -f $file ]] || continue
    names+=("$(basename "$file" .opt)")
  done
  if (( ${#names[@]} > 0 )); then
    mapfile -t TUI_NAMES < <(printf '%s\n' "${names[@]}" | sort -V)
  fi
  TUI_CURRENT=$(current_strategy)
  TUI_GAMES=$(current_games)
  TUI_VOICE=$(current_voice)
  TUI_MC=$(current_minecraft)
  if [[ $ZAPRET_HOME == "$MANAGED_PREFIX" ]]; then
    TUI_BOOT=$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || echo disabled)
  else
    TUI_BOOT=staging
  fi
  TUI_RESULTS=()
  if [[ -f $STATE_DIR/test-results ]]; then
    while read -r name score; do
      if [[ -n $name ]]; then
        TUI_RESULTS[$name]=$score
      fi
    done < "$STATE_DIR/test-results"
  fi
  local count=${#TUI_NAMES[@]}
  if (( count == 0 )); then
    TUI_SELECTED=0
    TUI_TOP=0
  else
    if (( TUI_SELECTED >= count )); then TUI_SELECTED=$((count - 1)); fi
    if (( TUI_SELECTED < 0 )); then TUI_SELECTED=0; fi
  fi
}

tui_select_current() {
  local i
  for i in "${!TUI_NAMES[@]}"; do
    if [[ ${TUI_NAMES[$i]} == "$TUI_CURRENT" ]]; then
      TUI_SELECTED=$i
      return 0
    fi
  done
  return 0
}

tui_flash() {
  TUI_FLASH=$1
  TUI_FLASH_KIND=${2:-info}
}

tui_flash_color() {
  case ${TUI_FLASH_KIND:-info} in
    ok) printf '%s' "$C_OK" ;;
    warn) printf '%s' "$C_WARN" ;;
    fail) printf '%s' "$C_FAIL" ;;
    *) printf '%s' "$C_DIM" ;;
  esac
}

tui_fail() {
  local msg=$1 line
  line=$(tail -n 1 "$TUI_LOG" 2>/dev/null || true)
  if [[ -n $line ]]; then
    tui_flash "$msg: $line" fail
  else
    tui_flash "$msg" fail
  fi
}

tui_status_line() {
  local pids pids_one state color q="$S_FAIL"
  pids=$(own_pids)
  pids_one=${pids%%$'\n'*}
  if queue_loaded; then
    q="$S_OK"
  fi
  if service_active; then
    state="$S_DOT active"
    color=$C_OK
    if [[ -z $pids_one || $q != "$S_OK" ]]; then
      state="$S_FAIL failed"
      color=$C_FAIL
    fi
  else
    state="$S_STOP stopped"
    color=$C_WARN
    if [[ $q == "$S_OK" ]]; then
      state="$S_DOT rules loaded"
    fi
  fi
  TUI_STATUS_COLOR=$color
  printf -v TUI_STATUS_TEXT '%s  nfqws %s  q%s %s  games %s  voice %s  mc %s' \
    "$state" "${pids_one:-$S_NONE}" "$NFQUEUE_NUM" "$q" "$TUI_GAMES" "$TUI_VOICE" "$TUI_MC"
}

tui_detail_build() {
  local name=${TUI_NAMES[$TUI_SELECTED]:-}
  local opt tcp udp score pcount testfile last w=$TUI_DETAIL_W line
  TUI_DETAIL=()
  if [[ -z $name ]]; then
    TUI_DETAIL+=("${C_DIM}no strategies in $PROFILES_DIR${C_RESET}")
    return
  fi
  opt=$PROFILES_DIR/$name.opt
  if [[ ! -f $opt || ! -f $PROFILES_DIR/$name.tcp || ! -f $PROFILES_DIR/$name.udp ]]; then
    TUI_DETAIL+=("${C_FAIL}missing profile files${C_RESET}")
    return
  fi
  tcp=$(<"$PROFILES_DIR/$name.tcp")
  udp=$(<"$PROFILES_DIR/$name.udp")
  score=${TUI_RESULTS[$name]:-}
  pcount=$(awk 'BEGIN{n=1} /^--new$/{n++} END{print n}' "$opt" 2>/dev/null)
  [[ -n $pcount ]] || pcount=1

  TUI_DETAIL+=("${C_BOLD}${name}${C_RESET}")
  if [[ $name == "$TUI_CURRENT" ]]; then
    TUI_DETAIL+=("${C_OK}${S_DOT} current${C_RESET}")
  else
    TUI_DETAIL+=("${C_DIM}differs from current: $(tui_trim "${TUI_CURRENT:-none}" 18)${C_RESET}")
  fi
  if [[ -z $score ]]; then
    TUI_DETAIL+=("${C_DIM}untested ${S_NONE} press t${C_RESET}")
  elif [[ $score == FAIL ]]; then
    TUI_DETAIL+=("${C_FAIL}${S_FAIL} FAIL${C_RESET}")
  else
    TUI_DETAIL+=("${C_DIM}probe${C_RESET} $score")
  fi
  testfile=$STATE_DIR/test-results
  if [[ -f $testfile ]]; then
    last=$(date -r "$testfile" '+%H:%M' 2>/dev/null || true)
    if [[ -n $last ]]; then
      TUI_DETAIL+=("${C_DIM}tested${C_RESET} $last")
    fi
  fi
  TUI_DETAIL+=("")
  TUI_DETAIL+=("${C_DIM}TCP${C_RESET}")
  while IFS= read -r line; do TUI_DETAIL+=("  $line"); done < <(tui_wrap "$tcp" $((w - 2)) 3)
  TUI_DETAIL+=("${C_DIM}UDP${C_RESET}")
  while IFS= read -r line; do TUI_DETAIL+=("  $line"); done < <(tui_wrap "$udp" $((w - 2)) 3)
  TUI_DETAIL+=("")
  TUI_DETAIL+=("${C_DIM}profiles${C_RESET} $pcount")
  TUI_DETAIL+=("${C_DIM}games${C_RESET} $TUI_GAMES  ${C_DIM}voice${C_RESET} $TUI_VOICE  ${C_DIM}mc${C_RESET} $TUI_MC")
  TUI_DETAIL+=("${C_DIM}boot${C_RESET} $TUI_BOOT")
}

tui_score_color() {
  local score=$1 p t
  if [[ $score == FAIL ]]; then printf '%s' "$C_FAIL"; return; fi
  if [[ $score != */* ]]; then printf '%s' "$C_DIM"; return; fi
  p=${score%/*} t=${score#*/}
  if [[ $p =~ ^[0-9]+$ && $t =~ ^[0-9]+$ ]] && (( p == t )); then
    printf '%s' "$C_OK"
  else
    printf '%s' "$C_WARN"
  fi
}

tui_render_row() {
  local idx=$1 w=$2 name=${TUI_NAMES[$1]}
  local marker=' ' dot=' ' score score_plain name_w name_disp pad sc
  if (( idx == TUI_SELECTED )); then
    marker=$S_BAR
  fi
  if [[ $name == "$TUI_CURRENT" ]]; then
    dot=$S_DOT
  fi
  score=${TUI_RESULTS[$name]:-}
  score_plain=${score:-$S_NONE}
  name_w=$((w - 4 - ${#score_plain} - 1))
  if (( name_w < 6 )); then name_w=6; fi
  name_disp=$(tui_trim "$name" "$name_w")
  pad=$((w - 4 - ${#name_disp} - ${#score_plain}))
  if (( pad < 1 )); then pad=1; fi

  if (( idx == TUI_SELECTED )); then
    printf '%s%s %s %s%*s%s%s' "$C_REV" "$marker" "$dot" "$name_disp" "$pad" '' "$score_plain" "$C_RESET"
    return
  fi
  sc=$(tui_score_color "$score")
  printf '%s%s%s %s%s%s %s' "$C_ACC" "$marker" "$C_RESET" "$C_OK" "$dot" "$C_RESET" "$name_disp"
  printf '%*s' "$pad" ''
  printf '%s%s%s' "$sc" "$score_plain" "$C_RESET"
}

tui_draw_small() {
  local cols=$1 rows=$2
  tput clear 2>/dev/null || printf '\033[2J'
  tui_at 1 1
  printf 'zapret needs 70x20 (now %sx%s)' "$cols" "$rows"
  tui_at 3 1
  printf 'q quit'
}

tui_draw() {
  local cols rows list_w detail_w body_top body_bottom list_h count i idx row
  local frow pad right
  cols=$(tui_cols)
  rows=$(tui_rows)
  if (( cols < 70 || rows < 20 )); then
    tui_draw_small "$cols" "$rows"
    return
  fi

  list_w=$((cols * 45 / 100))
  if (( list_w < 30 )); then list_w=30; fi
  if (( list_w > 44 )); then list_w=44; fi
  detail_w=$((cols - list_w - 1))
  TUI_DETAIL_W=$detail_w
  body_top=4
  body_bottom=$((rows - 4))
  list_h=$((body_bottom - body_top + 1))
  count=${#TUI_NAMES[@]}

  if (( count > 0 )); then
    if (( TUI_SELECTED >= count )); then TUI_SELECTED=$((count - 1)); fi
    if (( TUI_SELECTED < 0 )); then TUI_SELECTED=0; fi
    if (( TUI_SELECTED < TUI_TOP )); then TUI_TOP=$TUI_SELECTED; fi
    if (( TUI_SELECTED >= TUI_TOP + list_h )); then TUI_TOP=$((TUI_SELECTED - list_h + 1)); fi
    if (( TUI_TOP > count - list_h )); then TUI_TOP=$((count - list_h)); fi
    if (( TUI_TOP < 0 )); then TUI_TOP=0; fi
  else
    TUI_TOP=0
  fi

  local shown=$list_h range="0"
  if (( shown > count )); then shown=$count; fi
  if (( count > 0 )); then range="$((TUI_TOP + 1))-$((TUI_TOP + shown))"; fi

  tui_detail_build

  tui_at 1 1
  tui_status_line
  right=$TUI_STATUS_TEXT
  right=$(tui_trim "$right" $((cols - 8)))
  pad=$((cols - 6 - ${#right} - 1))
  if (( pad < 1 )); then pad=1; fi
  printf '%s%s%s%*s%s%s%s' "$C_BOLD" "zapret" "$C_RESET" "$pad" '' "${TUI_STATUS_COLOR:-}" "$right" "$C_RESET"
  printf '\033[K'

  tui_at 2 1
  printf '%s%s%s' "$C_DIM" "$(tui_hline "$cols")" "$C_RESET"
  printf '\033[K'

  tui_at 3 1
  printf '%sSTRATEGIES %d %s %s%s' "$C_DIM" "$count" "$S_MID" "$range" "$C_RESET"
  tui_at 3 $((list_w + 2))
  printf '%sDETAIL%s' "$C_DIM" "$C_RESET"
  printf '\033[K'

  for ((i = 0; i < list_h; i++)); do
    row=$((body_top + i))
    idx=$((TUI_TOP + i))
    tui_at "$row" 1
    if (( idx < count )); then
      tui_render_row "$idx" "$list_w"
    else
      printf '%*s' "$list_w" ''
    fi
    tui_at "$row" $((list_w + 1))
    printf '%s%s%s' "$C_DIM" "$S_V" "$C_RESET"
    tui_at "$row" $((list_w + 2))
    printf '%s' "${TUI_DETAIL[$i]:-}"
    printf '\033[K'
  done

  frow=$((rows - 3))
  tui_at "$frow" 1
  printf '%s%s%s' "$C_DIM" "$(tui_hline "$cols")" "$C_RESET"
  printf '\033[K'
  tui_at $((frow + 1)) 1
  printf '%s%s%s' "$C_DIM" "$(tui_trim "${S_UP}${S_DOWN} move  Enter apply  t test  T all  g games  v voice  m mc  s on/off  ? help  q quit" "$cols")" "$C_RESET"
  printf '\033[K'
  tui_at $((frow + 2)) 1
  if [[ -n $TUI_FLASH ]]; then
    printf '%s%s%s' "$(tui_flash_color)" "$(tui_trim "$TUI_FLASH" "$cols")" "$C_RESET"
  fi
  printf '\033[K'
}

tui_read_key() {
  local key c1 c2 c3
  if ! IFS= read -rsn1 -t 1 key; then
    return 1
  fi
  if [[ $key == $'\e' ]]; then
    if ! IFS= read -rsn1 -t 0.05 c1; then
      echo esc
      return 0
    fi
    case $c1 in
      '[')
        if ! IFS= read -rsn1 -t 0.05 c2; then
          echo esc
          return 0
        fi
        case $c2 in
          A) echo up ;;
          B) echo down ;;
          C) echo right ;;
          D) echo left ;;
          H) echo home ;;
          F) echo end ;;
          1|4|5|6)
            IFS= read -rsn1 -t 0.05 c3 || true
            case "$c2$c3" in
              1~) echo home ;;
              4~) echo end ;;
              5~) echo pgup ;;
              6~) echo pgdown ;;
              *) echo esc ;;
            esac
            ;;
          *) echo esc ;;
        esac
        ;;
      'O')
        if ! IFS= read -rsn1 -t 0.05 c2; then
          echo esc
          return 0
        fi
        case $c2 in
          A) echo up ;;
          B) echo down ;;
          C) echo right ;;
          D) echo left ;;
          H) echo home ;;
          F) echo end ;;
          *) echo esc ;;
        esac
        ;;
      *) echo esc ;;
    esac
    return 0
  fi
  case $key in
    k|K) echo up ;;
    j|J) echo down ;;
    '') echo enter ;;
    t) echo test ;;
    T) echo testall ;;
    g) echo games ;;
    v) echo voice ;;
    m) echo minecraft ;;
    s) echo service ;;
    r) echo refresh ;;
    '?'|h|H) echo help ;;
    q|Q) echo quit ;;
    *) echo none ;;
  esac
}

tui_move() {
  local delta=$1 count=${#TUI_NAMES[@]}
  (( count > 0 )) || return 0
  TUI_SELECTED=$((TUI_SELECTED + delta))
  if (( TUI_SELECTED < 0 )); then TUI_SELECTED=0; fi
  if (( TUI_SELECTED >= count )); then TUI_SELECTED=$((count - 1)); fi
}

tui_drain_input() {
  local _
  while IFS= read -rsn1 -t 0.02 _; do
    :
  done
}

tui_confirm() {
  local prompt=$1 key
  tui_flash "$prompt [y/N]" warn
  tui_draw
  if ! IFS= read -rsn1 -t 15 key; then return 1; fi
  tui_drain_input
  [[ $key == y || $key == Y ]]
}

tui_apply() {
  local name=${TUI_NAMES[$TUI_SELECTED]:-}
  [[ -n $name ]] || return 0
  tui_flash "applying $name..." warn
  tui_draw
  if (cmd_use "$name") >"$TUI_LOG" 2>&1; then
    tui_flash "applied $name" ok
  else
    tui_fail "apply failed"
  fi
  tui_reload
}

tui_games() {
  local next=on
  if [[ $TUI_GAMES == on ]]; then next=off; fi
  tui_flash "games $next..." warn
  tui_draw
  if (cmd_games "$next") >"$TUI_LOG" 2>&1; then
    tui_flash "games $next" ok
  else
    tui_fail "games failed"
  fi
  tui_reload
}

tui_voice() {
  local next=on
  if [[ $TUI_VOICE == on ]]; then next=off; fi
  tui_flash "voice $next..." warn
  tui_draw
  if (cmd_voice "$next") >"$TUI_LOG" 2>&1; then
    tui_flash "voice $next" ok
  else
    tui_fail "voice failed"
  fi
  tui_reload
}

tui_minecraft() {
  local next=on
  if [[ $TUI_MC == on ]]; then next=off; fi
  tui_flash "minecraft $next..." warn
  tui_draw
  if (cmd_minecraft "$next") >"$TUI_LOG" 2>&1; then
    tui_flash "minecraft $next" ok
  else
    tui_fail "minecraft failed"
  fi
  tui_reload
}

tui_service() {
  if service_active; then
    tui_confirm "Stop bypass?" || { tui_flash "cancelled" info; return 0; }
    tui_flash "stopping..." warn
    tui_draw
    if (cmd_off) >"$TUI_LOG" 2>&1; then tui_flash "stopped" ok; else tui_fail "stop failed"; fi
  else
    tui_flash "starting..." warn
    tui_draw
    if (cmd_on) >"$TUI_LOG" 2>&1; then tui_flash "started" ok; else tui_fail "start failed"; fi
  fi
  tui_reload
}

tui_run_test() {
  local rc=0
  tui_leave_screen
  printf '\n'
  (cmd_test "$@") || rc=$?
  printf '\nPress Enter to return to zapret...'
  IFS= read -r _ || true
  tui_enter_screen
  tui_reload
  return "$rc"
}

tui_test_selected() {
  local name=${TUI_NAMES[$TUI_SELECTED]:-}
  [[ -n $name ]] || return 0
  if tui_run_test "$name"; then
    tui_flash "test finished: $name" ok
  else
    tui_flash "test failed: $name" fail
  fi
}

tui_test_all() {
  tui_confirm "Test all ${#TUI_NAMES[@]} strategies? Takes 1-3 min" || { tui_flash "cancelled" info; return 0; }
  if tui_run_test; then
    tui_flash "test finished: all strategies" ok
  else
    tui_flash "test failed" fail
  fi
}

tui_help() {
  tput clear 2>/dev/null || printf '\033[2J'
  tui_at 2 2
  printf '%sControls%s' "$C_BOLD" "$C_RESET"
  local -a lines=(
    "${S_UP}/k, ${S_DOWN}/j       move selection"
    "PgUp/PgDn      page selection"
    "Home/End       first / last strategy"
    "Enter          apply selected strategy"
    "t              test selected strategy"
    "T              test all strategies"
    "g              toggle games filter"
    "v              toggle Discord RTC desync"
    "m              toggle Minecraft/Hypixel bypass"
    "s              start / stop bypass"
    "r              refresh status"
    "?/h            this help"
    "q              quit"
    ""
    "Esc closes this help."
  )
  local i=4 line
  for line in "${lines[@]}"; do
    tui_at "$i" 4
    printf '%s' "$line"
    i=$((i + 1))
  done
  IFS= read -rsn1 -t 30 _ || true
}

cmd_tui() {
  [[ -d $PROFILES_DIR ]] || die "Not installed: $PROFILES_DIR is missing"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  tui_color_init
  tui_set_symbols
  tui_enter_screen
  trap tui_cleanup EXIT INT TERM
  tui_reload
  tui_select_current
  local key
  while true; do
    tui_draw
    if ! key=$(tui_read_key); then
      continue
    fi
    if (( $(tui_cols) < 70 || $(tui_rows) < 20 )); then
      if [[ $key == quit ]]; then exit 0; fi
      continue
    fi
    case $key in
      up) tui_move -1 ;;
      down) tui_move 1 ;;
      pgup) tui_move -10 ;;
      pgdown) tui_move 10 ;;
      home) TUI_SELECTED=0 ;;
      end) TUI_SELECTED=$(( ${#TUI_NAMES[@]} - 1 )) ;;
      enter) tui_apply ;;
      test) tui_test_selected ;;
      testall) tui_test_all ;;
      games) tui_games ;;
      voice) tui_voice ;;
      minecraft) tui_minecraft ;;
      service) tui_service ;;
      refresh) tui_reload; tui_flash "refreshed $(date +%H:%M:%S)" ok ;;
      help) tui_help ;;
      quit) exit 0 ;;
      *) ;;
    esac
  done
}

tui_available() {
  [[ -t 0 && -t 1 ]] || return 1
  [[ ${TERM:-dumb} != dumb ]] || return 1
  command -v tput >/dev/null 2>&1 || return 1
  return 0
}
