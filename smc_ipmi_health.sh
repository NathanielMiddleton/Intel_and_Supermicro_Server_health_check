#!/usr/bin/env bash
# smc_ipmi_health.sh - Supermicro and Intel server-board hardware health, run on the server itself.
#   bash only, no jq, no Redfish. Any board with a standard IPMI BMC gets most of it; Supermicro (X9-X13, H11-H13)
#   and Intel (S2600 family, M50CYP, D50TNP) sensor naming and quirks are handled explicitly.
#   BMC via ipmitool over KCS (sensors, PSUs, chassis faults, SEL); inventory via dmidecode/sysfs; memory
#   errors via EDAC; drives via smartctl, storcli/perccli (MegaRAID), mdadm, zpool; NICs via sysfs;
#   GPUs via nvidia-smi (+ dmesg Xids, NVLink counters) and amdgpu sysfs.
# Usage: smc_ipmi_health.sh [-q] [-c|--clearsel] [SECTION...]
#   -q, --quiet     only print what is not OK (silent when healthy)
#   -c, --clearsel  if the SEL is at least SEL_CLEAR_AT % full, archive it in full to SEL_ARCHIVE and clear it;
#                   without this flag a full SEL is only reported (Warning), never touched
#   SECTION         report only these sections (any number, default all): --system --chassis --cpu --memory
#                   --temps --fans --voltages --power --storage --network --gpu --sel
#                   The summary, verdict and exit code then cover only the selected sections. Sections that
#                   do not need the BMC (--network, --gpu) run even where ipmitool or /dev/ipmi0 is missing.
# Env:  IPMITOOL_OPTS  extra ipmitool args; default is the local KCS interface (modprobe ipmi_si ipmi_devintf)
#       TOOL_TIMEOUT   seconds per external command, default 60
#       SEL_CLEAR_AT   fill level (%) at which --clearsel acts, default 90 (0 = always clear when --clearsel is given)
#       SEL_ARCHIVE    directory for the archived logs, default /var/log/ipmi-sel
#       SILENCE_FILE   default /tmp/healthcheck: section names to silence (same names as the --section flags, one
#                      per line or space separated, # comments; a directory whose entry names are sections also
#                      works; "all" silences everything). Silenced sections still run and print, but their
#                      Warning/Critical/ERROR lines are tagged [silenced] and ignored by the summary, the -q
#                      output and the exit code. Living in /tmp, the file disappears on reboot by design.
# Exit: 0 OK, 1 Warning, 2 Critical, 3 cannot check (BMC unreachable, or smartctl/storcli/nvidia-smi is
#       needed for installed hardware but missing)
# Every health line ends in ": OK", ": Warning", ": Critical" or ": ERROR"; summary and verdict are read from that.
set -u
export LC_ALL=C

usage() { sed -n '/^# Usage:/,/^# Env:/{/^# Env:/!s/^# \{0,1\}//p}' "$0"; }
sect() { case $1 in system|sys) echo system;; chassis) echo chassis;; processors|cpu|cpus|proc|procs) echo processors;;
         memory|mem|dimms|ram) echo memory;; temperatures|temps|temp|thermal) echo temperatures;; fans|fan) echo fans;;
         voltages|volts|voltage) echo voltages;; power|psu|psus) echo power;; storage|disks|disk|drives|raid) echo storage;;
         network|net|nics|nic) echo network;; gpus|gpu) echo gpus;; sel|log) echo sel;; esac; }
want() { [[ -z $only || " $only " == *" $1 "* ]]; }      # section selected (no selection = everything)
q=0; clearsel=0; only=; args=()
for a in "$@"; do case $a in
  --clearsel|--clear-sel) clearsel=1;; --quiet) args+=(-q);; -h|--help) usage; exit 0;;
  --*) x=$(sect "${a#--}"); [[ $x ]] || { echo "unknown option $a" >&2; usage >&2; exit 3; }; only+=" $x";;
  *) args+=("$a");; esac; done
set -- ${args[@]+"${args[@]}"}
: "${SEL_CLEAR_AT:=90}" "${SEL_ARCHIVE:=/var/log/ipmi-sel}"; [[ $SEL_CLEAR_AT =~ ^[0-9]+$ ]] || SEL_CLEAR_AT=90
while getopts ":qch" o; do case $o in q) q=1;; c) clearsel=1;; h) usage; exit 0;; *) usage >&2; exit 3;; esac; done
needbmc=0; for x in system chassis processors memory temperatures fans voltages power storage sel; do want $x && needbmc=1; done
: "${SILENCE_FILE:=/tmp/healthcheck}"; silenced=; silbad=; words=
if   [[ -d $SILENCE_FILE ]]; then words=$(ls -A "$SILENCE_FILE" 2>/dev/null)
elif [[ -f $SILENCE_FILE ]]; then words=$(sed 's/#.*//' "$SILENCE_FILE" 2>/dev/null); fi
for w in $words; do
  if [[ ${w,,} == all ]]; then silenced=" system chassis processors memory temperatures fans voltages power storage network gpus sel"
  else x=$(sect "${w,,}"); if [[ $x ]]; then silenced+=" $x"; else silbad+=" $w"; fi; fi
done

have() { command -v "$1" >/dev/null 2>&1; }
run()  { timeout "${TOOL_TIMEOUT:-60}" "$@" 2>/dev/null </dev/null; }      # external tool, stderr dropped
ipmi() { run ipmitool ${IPMITOOL_OPTS:-} "$@"; }
num()  { [[ ${1:-} =~ ^[0-9]+$ ]]; }
dmi()  { cat "/sys/class/dmi/id/$1" 2>/dev/null; }
# kv KEY_RE TEXT [SEP]: value of the first "key SEP value" line whose trimmed key matches KEY_RE
kv() { awk -v k="$1" -v s="${3:-:}" '(i=index($0,s)){a=substr($0,1,i-1); gsub(/^[ \t]+|[ \t]+$/,"",a)
        if(a~"^("k")$"){v=substr($0,i+length(s)); gsub(/^[ \t]+|[ \t]+$/,"",v); print v; exit}}' <<<"$2"; }
# flag STATUS [REASON]: raise caller's $st (Critical > Warning > ERROR > OK) and append REASON to $why
flag() { case "$st $1" in *Critical*) st=Critical;; *Warning*) st=Warning;; *ERROR*) st=ERROR;; *) st=OK;; esac
         [[ ${2:-} ]] && why+="${why:+, }$2"; return 0; }

# --- BMC sensors: $SDR holds "ipmitool sdr elist" as name|id|status|entity|reading lines ---
ipst() { case $1 in ok) echo OK;; nc|lnc|unc) echo Warning;; cr|nr|lcr|ucr|lnr|unr) echo Critical;; ns|na) echo;; *) echo Warning;; esac; }
BAD='Failure detected|Fault|Uncorrectable|Thermal Trip|IERR|Non-?[Rr]ecoverable|Transition to Critical|AC lost|input lost|out-of-range|Device Disabled|FRB|Limit Exceeded|Overload|Insufficient|In Critical Array|In Failed Array'
WARN='Predictive|Correctable|Non-?[Cc]ritical|[Ii]ntrusion|Config(uration)? Error|Redundancy Lost|Non-?[Rr]edundant|Degraded|Logging Disabled|Timer expired|Hard Reset|Power Down|Power Cycle|Throttl|Over-?[Tt]emp|Rebuild|Remap|Almost Full|Log Full|SEL Full'
dst()  { if [[ $1 =~ $BAD ]]; then echo Critical; elif [[ $1 =~ $WARN ]]; then echo Warning; else echo OK; fi; }
thr()  { ipmi sensor get "$1" | awk -F': *' '/^ (Lower|Upper) (Non-Critical|Critical|Non-Recoverable)/ && $2!="na" {
           printf "%s%s%s %g", (c++?" ":""), tolower(substr($1,2,1)), ($1~/Non-C/?"nc":$1~/Non-R/?"nr":"cr"), $2}'; }
RE_MEM='DIMM|MEM|Mem'; RE_CPU='CPU|Proc|^P[0-9]+ '; RE_PSU='^PS[0-9]|Power Supply|PSU|PWR'     # Intel BMC: "P1 Status", "Mem P1 Thrm Trip"
RE_DRV='HDD|Drive|SAS|NVMe|SSD|Disk|Slot|M2|M\.2|BPN|Backplane'
# sensors t UNIT_RE: threshold sensors whose reading matches; sensors d|D NAME_RE: discrete sensors whose name matches|doesn't
# Presence-style discrete sensors with an empty reading are not printed but appended to ABSENT (callers reset and report it)
ABSENT=()
sensors() {
  local n id s e r w t
  while IFS='|' read -r -u3 n id s e r; do
    [[ $n ]] || continue
    if [[ $1 == t ]]; then
      [[ $r =~ $2 ]] || continue; w=$(ipst "$s"); [[ $w ]] || continue      # ns/na = not installed, like Absent
      [[ $n =~ Margin|Mrgn ]] && r+=" (thermal margin: negative = headroom)"   # Intel BMC reports CPU/DIMM margin to Tcontrol
      if [[ $w == OK ]]; then echo "  $n $r: OK"; else t=$(thr "$n"); echo "  $n $r${t:+ (thresholds $t)}: $w"; fi
    else
      [[ $r =~ (degrees|RPM|Volts|Watts|Amps|^No Reading$) || $s == ns || $s == na ]] && continue
      if [[ $1 == d ]]; then [[ $n =~ $2 ]] || continue; else [[ $n =~ $2 ]] && continue; fi
      [[ -z $r && $s == ok && $n =~ Status$ ]] && { ABSENT+=("$n"); continue; }   # "HDD 3 Status" with nothing asserted = empty bay, not a healthy drive
      w=$(dst "$r"); t=$(ipst "$s"); [[ $t == Critical || ( $t == Warning && $w == OK ) ]] && w=$t   # "P1 Therm Ctrl %", "System Airflow" carry status, not text
      echo "  $n${r:+ $r}: $w"
    fi
  done 3<<<"$SDR"
}

processors() {
  local n
  echo "Processors:"
  if have dmidecode; then
    run dmidecode -t processor | awk -F': *' '
      function out(){ if(s!="" && t!~/Unpopulated/){ gsub(/\(R\)|\(TM\)|\(tm\)| CPU @.*| @.*/,"",v); gsub(/  +/," ",v)
        printf "  %s %s %sc/%st (%s): %s\n", s, v, c, th, t, (t~/Enabled/?"OK":"Warning") } s=v=t=c=th="" }
      /^Handle/{out()} /^\tSocket Designation:/{s=$2} /^\tVersion:/{v=$2} /^\tStatus:/{t=$2}
      /^\tCore Count:/{c=$2} /^\tThread Count:/{th=$2} END{out()}'
  else echo "  dmidecode not installed, $(nproc) logical CPUs"; fi
  n=$(grep -cE 'mce: \[Hardware Error\]|Machine check events logged' <<<"$DMESG")
  echo "  machine check (MCE) lines in dmesg $n: $([[ $n == 0 ]] && echo OK || echo Warning)"
  ABSENT=(); sensors d "$RE_CPU"                                       # empty "P2 Status" = unpopulated socket, dmidecode already said so
}

memory() {
  local os mc d ce ue st why n=0
  os=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ))
  if have dmidecode; then
    run dmidecode -t memory | awk -F': *' -v os="$os" '
      function out(){ if(m && l!="" && sz~/^[0-9]/){ split(sz,a," "); t+=(a[2]=="MB")?a[1]/1024:a[1]; gsub(/ +$/,"",pn)
        L[++n]=sprintf("  %s %s %s %s %s %s", l, sz, ty, sp, mf, pn) } m=0 }
      /^Handle/{out()} /^Memory Device$/{m=1; l=sz=ty=sp=mf=pn=""}
      m&&/^\tLocator:/{l=$2} m&&/^\tSize:/{sz=$2} m&&/^\tType:/{ty=$2} m&&/^\tSpeed:/{sp=$2}
      m&&/^\tManufacturer:/{mf=$2} m&&/^\tPart Number:/{pn=$2}
      END{ out(); printf "Memory: %d GiB in %d DIMMs, %d GiB usable by the OS\n", t, n, os; for(i=1;i<=n;i++) print L[i] }'
  else echo "Memory: $os GiB usable by the OS (dmidecode not installed)"; fi
  for mc in /sys/devices/system/edac/mc/mc[0-9]*; do                     # OS-side ECC counters
    [[ -r $mc/ce_count ]] || continue; (( n++ )); ce=$(<"$mc/ce_count"); ue=$(<"$mc/ue_count"); st=OK; why=
    (( ue )) && flag Critical; (( ce )) && flag Warning
    echo "  edac $(<"$mc/mc_name") CE $ce UE $ue: $st"
    for d in "$mc"/dimm[0-9]* "$mc"/rank[0-9]*; do
      [[ -r $d/dimm_ce_count ]] || continue; ce=$(<"$d/dimm_ce_count"); ue=$(<"$d/dimm_ue_count"); (( ce || ue )) || continue
      echo "    $(<"$d/dimm_label") CE $ce UE $ue: $( (( ue )) && echo Critical || echo Warning )"
    done
  done
  (( n )) || echo "  edac not loaded, no OS-side ECC counters"
  ABSENT=(); sensors d "$RE_MEM"
}

drive() {   # drive DEV TYPE: one smartctl line (SATA, SAS, NVMe, drives behind MegaRAID)
  local s m sn h w bad cw me sp spt gd st=OK why=
  s=$(run smartctl -H -i -A -d "$2" "$1")
  [[ $s ]] || { echo "    drive $1 ($2) smartctl got nothing: ERROR"; return; }
  m="$(kv Vendor "$s") $(kv 'Device Model|Model Number|Product' "$s")"; m=${m# }; sn=$(kv 'Serial [Nn]umber' "$s")
  h=$(kv 'SMART overall-health self-assessment test result|SMART Health Status' "$s")
  [[ $h ]] || { echo "    drive $1 $m $sn: no SMART health available"; return; }
  [[ $h == PASSED || $h == OK ]] || flag Critical "health $h"
  w=$(kv 'Percentage Used|Percentage used endurance indicator' "$s"); w=${w%\%}                     # NVMe, SAS
  num "$w" || w=$(awk '$2~/Wearout|Lifetime_Remain|Life_Left|Life_Remaining|Wear_Leveling|Rated_Life_Remain/ && $4~/^[0-9]+$/{print 100-$4; exit}' <<<"$s")
  if [[ $s == *ATTRIBUTE_NAME* ]]; then      # ATA: 5 reallocated (retired NAND blocks on SSDs), 197 pending, 198/187 uncorrectable
    bad=$(awk '($1==5||$1==187||$1==197||$1==198)&&NF>=10&&$10+0>0{printf "%s%s %d",(n++?" ":""),($1==5?"reallocated":$1==197?"pending":$1==198?"offline-uncorrectable":"reported-uncorrectable"),$10}' <<<"$s")
    [[ $bad ]] && flag Warning "$bad"
  fi
  cw=$(kv 'Critical Warning' "$s"); me=$(kv 'Media and Data Integrity Errors' "$s"); me=${me//,/}  # NVMe
  sp=$(kv 'Available Spare' "$s"); sp=${sp%\%}; spt=$(kv 'Available Spare Threshold' "$s"); spt=${spt%\%}
  [[ -z $cw || $cw == 0x00 ]] || flag Critical "critical warning $cw"
  num "$me" && (( me )) && flag Warning "media errors $me"
  num "$sp" && num "$spt" && (( sp < spt )) && flag Critical "spare $sp% < $spt%"
  gd=$(kv 'Elements in grown defect list' "$s"); num "$gd" && (( gd )) && flag Warning "grown defects $gd"   # SAS
  echo "    drive $1 $m $sn${w:+, ${w}% used}${why:+, $why}: $st"
}

storage() {
  local cli n c o s w m ce ue raid st why
  echo "Storage:"
  raid=$(run lspci | grep -i 'RAID bus controller' | sed 's/^[^:]*: //; s/ (rev.*//')
  cli=$(command -v storcli64 storcli perccli64 perccli 2>/dev/null | head -1)
  [[ $cli ]] || for c in /opt/MegaRAID/storcli/storcli64 /opt/MegaRAID/perccli/perccli64; do [[ -x $c ]] && { cli=$c; break; }; done
  if [[ $cli ]]; then
    n=$(kv 'Number of Controllers' "$(run "$cli" show nolog)" =); n=${n:-0}
    for ((c=0; c<n; c++)); do
      o=$(run "$cli" /c$c show all nolog); s=$(kv 'Controller Status' "$o" =)
      ce=$(kv 'Memory Correctable Errors' "$o" =); ue=$(kv 'Memory Uncorrectable Errors' "$o" =); st=OK; why=
      case $s in Optimal) ;; "Needs Attention") flag Warning;; "") flag ERROR;; *) flag Critical;; esac
      num "$ue" && (( ue )) && flag Critical
      echo "  $(kv 'Product Name' "$o" =) SN $(kv 'Serial Number' "$o" =) fw $(kv 'FW Version' "$o" =), status ${s:-unknown}, memory errors ${ce:-?}/${ue:-?}: $st"
      # Cachevault_Info/BBU_Info table: Model State ...; VD LIST: DG/VD TYPE State ... Size Name; PD LIST: EID:Slt DID State DG Size Intf Med SED PI SeSz Model Sp Type
      awk '/^(Cachevault|BBU)_Info/{f=1;next} f && $1!="Model" && /^[A-Za-z0-9]+ +[A-Za-z]+ /{printf "    cache %s %s: %s\n",$1,$2,($2=="Optimal"?"OK":"Warning"); f=0}' <<<"$o"
      awk '/^[0-9]+\/[0-9]+ +[A-Za-z0-9]+ +[A-Za-z]+ /{w=($3=="Optl")?"OK":($3=="OfLn")?"Critical":"Warning"; n=""; for(i=11;i<=NF;i++) n=n" "$i
           printf "    volume %s %s %s %s%s %s: %s\n",$1,$2,$9,$10,n,$3,w}' <<<"$o"
      awk '/^[0-9]*:[0-9]+ +[0-9]+ +[A-Za-z]+ /{s=$3; w=(s~/^(Onln|GHS|DHS|JBOD|UGood)$/)?"OK":(s~/^(UBad|Offln|Failed|Msng)$/)?"Critical":"Warning"
           m=""; for(i=12;i<=NF-2;i++) m=m" "$i; printf "    pd %s %s%s %s %s %s: %s\n",$1,$7,m,$5,$6,s,w}' <<<"$o"
    done
  elif grep -qiE 'MegaRAID|LSI|Broadcom|Avago' <<<"$raid"; then echo "  $raid, storcli not installed: ERROR"
  elif grep -qiE 'Intel.*(VMD|Volume Management|RAID)' <<<"$raid"; then echo "  $raid: Intel VROC/RSTe, arrays appear as md devices below"
  elif [[ $raid ]]; then echo "  $raid: no supported CLI, RAID state not checked"
  fi
  if [[ -r /proc/mdstat ]] && have mdadm; then
    for m in $(awk '/^md[0-9]+ *:/{print $1}' /proc/mdstat); do
      o=$(run mdadm --detail "/dev/$m"); s=$(kv State "$o")
      [[ $(kv 'Raid Level' "$o") == container ]] && { echo "  md $m $(kv Version "$o") container, member arrays $(kv 'Member Arrays' "$o")"; continue; }   # VROC/RSTe imsm, DDF
      case $s in *FAILED*|*inactive*) w=Critical;; *degraded*|*recovering*|*resyncing*|*reshaping*) w=Warning;; "") w=ERROR;; *) w=OK;; esac
      echo "  md $m $(kv 'Raid Level' "$o") ${s:-unreadable}: $w"
    done
  fi
  have zpool && while read -r -u3 m s; do [[ $m ]] || continue; case $s in ONLINE) w=OK;; DEGRADED) w=Warning;; *) w=Critical;; esac
    echo "  zpool $m $s: $w"; done 3< <(run zpool list -H -o name,health)
  if have smartctl; then
    while read -r -u3 m _ s _; do [[ $m == /dev/* ]] && drive "$m" "$s"; done 3< <(run smartctl --scan-open)
  else echo "  smartctl not installed, drive SMART not checked: ERROR"; fi
  ABSENT=(); sensors d "$RE_DRV"; (( ${#ABSENT[@]} )) && echo "  ${#ABSENT[@]} empty drive bays"
  return 0
}

network() {   # physical NICs that are administratively up; no carrier only matters if the port is meant to carry traffic
  local d i f op sp drv cfg
  echo "Network:"
  for d in /sys/class/net/*/device; do
    [[ -e $d ]] || continue; i=${d%/device}; i=${i##*/}
    f=$(<"/sys/class/net/$i/flags"); (( f & 1 )) || continue
    op=$(<"/sys/class/net/$i/operstate"); sp=$(cat "/sys/class/net/$i/speed" 2>/dev/null); num "$sp" || sp=?; drv=$(basename "$(readlink "$d/driver" 2>/dev/null)")
    cfg=; [[ -e /sys/class/net/$i/master ]] && cfg="member of $(basename "$(readlink "/sys/class/net/$i/master")")"
    [[ $cfg ]] || { have ip && cfg=$(ip -o addr show dev "$i" scope global 2>/dev/null | awk '{print "has address "$4; exit}'); }
    case $op in up) echo "  $i $drv $sp Mb/s: OK";; unknown) echo "  $i $drv link state unknown: OK";;
      *) if [[ $cfg ]]; then echo "  $i $drv no carrier but $cfg: Warning"; else echo "  $i $drv no carrier, unplugged spare port"; fi;; esac
  done
}

nvidia() {   # nvidia N_ON_PCIE
  local core err n q i bus name sn drv t pd pl fan util mu mt ecc cv uv ua rp gc gm wc wm bk rc ru rpn rf hs hts sts pc e st why
  declare -A TH=() RR=() XN=() XL=() XC=() NV=()
  have nvidia-smi || { echo "  $1 NVIDIA GPUs on PCIe, nvidia-smi not installed: ERROR"; return; }
  core=$(timeout "${TOOL_TIMEOUT:-60}" nvidia-smi --query-gpu=index,pci.bus_id,name,serial,driver_version,temperature.gpu,power.draw,power.limit,fan.speed,utilization.gpu,memory.used,memory.total,ecc.mode.current,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.uncorrected.aggregate.total,retired_pages.pending,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits 2>&1 </dev/null | sed 's/, /,/g')
  err=$(grep -vE '^[0-9]+,' <<<"$core"); core=$(grep -E '^[0-9]+,' <<<"$core"); n=$(grep -c . <<<"$core")
  while read -r -u3 e; do [[ $e ]] || continue     # e.g. "Unable to determine the device handle for GPU 0000:C1:00.0: GPU is lost"
    case $e in *"communicate with the NVIDIA driver"*) st=ERROR;; *WARNING*) st=Warning;; *) st=Critical;; esac; echo "  nvidia-smi: $e: $st"
  done 3<<<"$err"
  (( n < $1 )) && echo "  NVIDIA GPUs: lspci sees $1, driver sees $n: Critical"
  (( n )) || return
  for q in clocks_throttle_reasons clocks_event_reasons; do    # renamed in R535
    while IFS=, read -r -u3 i hs hts sts pc; do TH[$i]="$hs,$hts,$sts,$pc"; done 3< <(run nvidia-smi --query-gpu=index,$q.hw_slowdown,$q.hw_thermal_slowdown,$q.sw_thermal_slowdown,$q.sw_power_cap --format=csv,noheader | grep -E '^[0-9]+,' | sed 's/, /,/g')
    (( ${#TH[@]} )) && break
  done
  while IFS=, read -r -u3 bus rc; do [[ $bus == *:* ]] && RR[$bus]=$rc; done 3< <(run nvidia-smi --query-remapped-rows=gpu_bus_id,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv,noheader | sed 's/, /,/g')
  # Xids since boot, keyed by bus:dev; 48 63 64 74 79 92 94 95 119 120 are hardware faults (DBE, row remap, NVLink, fell off bus, GSP)
  while read -r -u3 bk rc; do XN[$bk]=$(( ${XN[$bk]:-0} + 1 )); XL[$bk]=$rc
    [[ " 48 63 64 74 79 92 94 95 119 120 " == *" $rc "* ]] && XC[$bk]=$(( ${XC[$bk]:-0} + 1 ))
  done 3< <(grep -oE 'NVRM: Xid \(PCI:[0-9a-fA-F:]+\): [0-9]+' <<<"$DMESG" | sed -E 's/.*PCI:[0-9a-fA-F]+:([0-9a-fA-F]+:[0-9a-fA-F]+)\): ([0-9]+)/\L\1 \2/')
  while read -r -u3 i rc; do NV[$i]=$rc; done 3< <(run nvidia-smi nvlink -e | awk '/^GPU [0-9]+:/{g=$2; sub(":","",g)} /Errors: *[0-9]+ *$/{e[g]+=$NF} END{for(g in e) print g, e[g]}')
  echo "  driver $(cut -d, -f5 <<<"$core" | head -1), $n GPUs"
  while IFS=, read -r -u3 i bus name sn drv t pd pl fan util mu mt ecc cv uv ua rp gc gm wc wm; do
    st=OK; why=; bk=${bus#*:}; bk=${bk%.*}; bk=${bk,,}; [[ $bk ]] || bk=-
    IFS=, read -r rc ru rpn rf <<<"${RR[$bus]:-,,,}"; IFS=, read -r hs hts sts pc <<<"${TH[$i]:-,,,}"
    num "$uv" && (( uv )) && flag Critical "uncorrected ECC $uv"
    [[ $rp == Yes ]] && flag Warning "retired pages pending, reset needed"
    [[ $rpn == Yes ]] && flag Warning "row remap pending, reset needed"
    [[ $rf == Yes ]] && flag Critical "row remap failure"
    [[ $hs == Active ]] && flag Warning "HW slowdown"; [[ $hts == Active ]] && flag Warning "HW thermal slowdown"; [[ $sts == Active ]] && flag Warning "SW thermal slowdown"
    num "$wc" && num "$wm" && (( wc < wm )) && flag Warning "PCIe x$wc of x$wm"
    if (( ${XC[$bk]:-0} )); then flag Critical "Xid ${XL[$bk]} (${XN[$bk]} Xids in dmesg)"
    elif (( ${XN[$bk]:-0} )); then why+="${why:+, }${XN[$bk]} Xids in dmesg, last ${XL[$bk]}"; fi
    (( ${NV[$i]:-0} )) && flag Warning "NVLink errors ${NV[$i]}"
    e="ECC ${ecc,,}"; [[ $ecc == Enabled ]] && e+=" corr $cv uncorr $uv lifetime-uncorr $ua${ru:+ remapped-rows $rc/$ru}"
    echo "  GPU$i $name SN $sn: ${t}C ${pd}/${pl}W$(num "$fan" && echo " fan $fan%") util ${util}% mem ${mu}/${mt}MiB, $e, PCIe gen$gc/$gm x$wc/$wm${why:+, $why}: $st"
  done 3<<<"$core"
}

gpus() {
  local pci nv amd n d bdf name hw t p busy vu vt f b ce ue st why
  echo "GPUs:"
  have lspci || { echo "  lspci not installed, cannot enumerate GPUs: ERROR"; return; }
  pci=$(run lspci -Dnn | grep -E '^[0-9a-f:.]+ [^[]*\[03[0-9a-f]{2}\]: ' | grep -vE '\[1a03:|\[102b:')   # display class, minus the BMC's own VGA
  [[ $pci ]] || { echo "  none"; return; }
  nv=$(grep -c '\[10de:' <<<"$pci"); amd=$(grep -c '\[1002:' <<<"$pci")
  (( nv )) && nvidia "$nv"
  if (( amd )); then
    n=0
    for d in /sys/class/drm/card*/device; do
      [[ $d =~ /card[0-9]+/device$ && -r $d/vendor && $(<"$d/vendor") == 0x1002 ]] || continue
      (( n++ )); bdf=$(basename "$(readlink -f "$d")"); st=OK; why=
      name=$(cat "$d/product_name" 2>/dev/null); [[ $name ]] || name=$(run lspci -s "$bdf" | sed 's/^[^ ]* [^:]*: //; s/ (rev.*//')
      hw=$(echo "$d"/hwmon/hwmon*); t=$(cat "$hw/temp1_input" 2>/dev/null); p=$(cat "$hw/power1_average" "$hw/power1_input" 2>/dev/null | head -1)
      busy=$(cat "$d/gpu_busy_percent" 2>/dev/null); vu=$(cat "$d/mem_info_vram_used" 2>/dev/null); vt=$(cat "$d/mem_info_vram_total" 2>/dev/null)
      for f in "$d"/ras/*_err_count; do         # amdgpu RAS blocks (umc = HBM, gfx, sdma, ...): "ue: N" / "ce: N"
        [[ -r $f ]] || continue; b=$(basename "$f" _err_count); ue=$(awk '/^ue/{print $2}' "$f"); ce=$(awk '/^ce/{print $2}' "$f")
        num "$ue" && (( ue )) && flag Critical "$b UE $ue"; num "$ce" && (( ce )) && flag Warning "$b CE $ce"
      done
      echo "  $name ($bdf): ${t:+$((t/1000))C }${p:+$((p/1000000))W }util ${busy:-?}% vram $(( ${vu:-0}/1048576 ))/$(( ${vt:-0}/1048576 ))MiB, PCIe x$(cat "$d/current_link_width" 2>/dev/null)/x$(cat "$d/max_link_width" 2>/dev/null)${why:+, $why}: $st"
    done
    (( n == 0 )) && echo "  AMD GPUs: lspci sees $amd, amdgpu driver not loaded: ERROR"
    (( n && n < amd )) && echo "  AMD GPUs: lspci sees $amd, amdgpu driver sees $n: Critical"
  fi
  grep -vE '\[10de:|\[1002:' <<<"$pci" | sed 's/^[^ ]* [^:]*: /  /; s/ \[[0-9a-f:]*\]//g; s/$/: not monitored/'
}

sel() {
  local i e p f n last
  echo "SEL:"
  i=$(ipmi sel info); e=$(kv Entries "$i"); p=$(kv 'Percent Used' "$i"); p=${p%\%}; num "$p" || p=
  if (( clearsel )) && num "$p" && (( p >= SEL_CLEAR_AT )); then
    # --clearsel: IPMI has no truncate, only clear, and a full SEL stops recording. Archive every entry first,
    # verify the dump is complete (a KCS timeout must never cost us the log), then clear so the BMC can log again.
    mkdir -p "$SEL_ARCHIVE" 2>/dev/null; f="$SEL_ARCHIVE/sel-$(hostname -s)-$(date +%Y%m%d-%H%M%S)-$$.log"
    { echo "$i"; echo; TOOL_TIMEOUT=900 ipmi sel elist; } > "$f" 2>/dev/null; n=$(grep -c '|' "$f" 2>/dev/null)
    if (( n > 0 )) && { ! num "$e" || (( n >= e )); } && ipmi sel clear >/dev/null; then
      logger -t smc_ipmi_health "SEL ${e:-?} entries, $p% full: archived $n entries to $f and cleared" 2>/dev/null
      echo "  ${e:-?} entries, $p% used: archived to $f and cleared: OK"; last=$(grep '|' "$f" | tail -5)
    else
      echo "  ${e:-?} entries, $p% used, nearly full; archive to $SEL_ARCHIVE incomplete ($n of ${e:-?}), not cleared: Warning"; last=$(ipmi sel elist last 5)
    fi
  elif num "$p" && (( p >= 90 )); then echo "  ${e:-?} entries, $p% used, nearly full, BMC will stop logging (run with --clearsel to archive and clear): Warning"; last=$(ipmi sel elist last 5)
  else echo "  ${e:-?} entries${p:+, $p% used}: OK"; last=$(ipmi sel elist last 5); fi
  grep '|' <<<"$last" | sed 's/ *| */ | /g; s/^ */  /'
}

system() {
  local ch s ip
  ch=$(ipmi chassis status)
  for s in 1 8 3 2; do ip=$(kv 'IP Address' "$(ipmi lan print $s)"); [[ $ip && $ip != 0.0.0.0 ]] && break; done   # Supermicro ch 1 (8 on some X13), Intel dedicated RMM = ch 3
  echo "System: $(dmi sys_vendor) $(dmi product_name) SN $(dmi product_serial), board $(dmi board_name) SN $(dmi board_serial), power $(kv 'System Power' "$ch"), BIOS $(dmi bios_version) ($(dmi bios_date)), BMC $(kv 'Manufacturer Name' "$MC") $(kv 'Firmware Revision' "$MC") at ${ip:-?}"
}

chassis() {
  local ch v s
  ch=$(ipmi chassis status)
  echo "Chassis:"
  [[ $SDR ]] || echo "  BMC sensor repository (ipmitool sdr elist) is empty or unreadable: ERROR"
  for s in 'Power Overload' 'Main Power Fault' 'Power Control Fault' 'Drive Fault' 'Cooling/Fan Fault'; do
    v=$(kv "$s" "$ch"); [[ $v ]] && echo "  $s $v: $([[ $v == false ]] && echo OK || echo Critical)"; done
  v=$(kv 'Chassis Intrusion' "$ch"); [[ $v ]] && { [[ $v == inactive ]] && echo "  Chassis Intrusion inactive: OK" || echo "  Chassis Intrusion $v (latched until cleared in the BMC, not judged)"; }
  # misc discrete sensors: intrusion, watchdogs, buttons, presence, redundancy ... (Intel BMCs have dozens). Only Critical-class
  # readings count here; Warning-class ones (latched intrusion, stale watchdog/power events, lost redundancy) are shown but not
  # scored, since the primary fan/PSU/temperature sensors already cover anything that is actually wrong right now
  s=$(sensors D "$RE_MEM|$RE_CPU|$RE_PSU|$RE_DRV" | sed 's/: Warning$/ (not judged)/')
  grep -v ': OK$' <<<"$s" | grep .; v=$(grep -c ': OK$' <<<"$s"); (( v )) && echo "  $v other discrete sensors: OK"
}

power() {
  local v
  v=$(kv 'Instantaneous power reading' "$(ipmi dcmi power reading)")
  [[ $v ]] || v=$(awk -F'|' '$1 ~ /^PS[0-9]+ (Power In|Input Power)$/ && $5 ~ /Watts/ {w+=$5+0} END{if(w) print w" Watts (sum of PSU inputs)"}' <<<"$SDR")   # no DCMI: add up Intel "PSn Power In"
  echo "Power:${v:+ $v in use}"
  sensors t 'Watts|Amps'; ABSENT=(); sensors d "$RE_PSU"
  for v in ${ABSENT[@]+"${ABSENT[@]}"}; do echo "  $v: no PSU detected in this slot"; done
}

report() {   # every section is its own function; a selection on the command line (--storage ...) picks which ones run
  want system       && system
  want chassis      && chassis
  want processors   && processors
  want memory       && memory
  want temperatures && { echo "Temperatures:"; sensors t degrees; }
  want fans         && { echo "Fans:"; sensors t RPM; }
  want voltages     && { echo "Voltages:"; sensors t Volts; }
  want power        && power
  want storage      && storage
  want network      && network
  want gpus         && gpus
  want sel          && sel
  return 0
}

(( EUID == 0 )) || { echo "UNKNOWN: run as root (ipmitool, dmidecode, smartctl need it)"; exit 3; }
MC=; SDR=; DMESG=
if (( needbmc )); then
  have ipmitool || { echo "UNKNOWN: ipmitool not installed"; exit 3; }
  MC=$(ipmi mc info)
  [[ $MC == *"Firmware Revision"* ]] || { echo "UNKNOWN: ipmitool cannot reach the BMC (modprobe ipmi_si ipmi_devintf, ipmi_ssif on some boards, or set IPMITOOL_OPTS)"; exit 3; }
  SDR=$(ipmi sdr elist | sed 's/ *| */|/g; s/^ *//; s/ *$//')
fi
{ want processors || want gpus; } && DMESG=$(run dmesg)
out=$(report)
[[ $silenced ]] && out=$(awk -v sil="$silenced " '/^[^ ]/{sec=tolower($1); sub(/:.*/,"",sec); z=index(sil," "sec" ")>0}
                                              z && /: (Warning|Critical|ERROR)$/{sub(/: (Warning|Critical|ERROR)$/,"& [silenced]")} {print}' <<<"$out")
silnote=; [[ $silenced ]] && silnote="Silenced via $SILENCE_FILE:$silenced${silbad:+ (unknown, ignored:$silbad)}"
[[ $silbad && -z $silenced ]] && silnote="Silence file $SILENCE_FILE: unknown section name(s):$silbad (nothing silenced)"

# verdict from the text: Critical > Warning > ERROR > OK
if   grep -qE ': Critical$' <<<"$out"; then rc=2; v=CRITICAL
elif grep -qE ': Warning$'  <<<"$out"; then rc=1; v=WARNING
elif grep -qE ': ERROR$'    <<<"$out"; then rc=3; v=UNKNOWN
else rc=0; v=OK; fi

if (( q )); then (( rc )) && { echo "$(hostname -s) $v"; [[ $silnote ]] && echo "$silnote"; grep -E ': (Critical|Warning|ERROR)$' <<<"$out"; }
else
  [[ $out == System:* ]] && { head -1 <<<"$out"; out=$(tail -n +2 <<<"$out"); }
  awk '/^[^ ]/{sec=tolower($1); sub(/:.*/,"",sec); next}          # worst status per section; silenced sections say so
       /: (OK|Warning|Critical|ERROR)$/{r=($NF=="Critical")?3:($NF=="Warning")?2:($NF=="ERROR")?1:0
         if(!(sec in w)){o[++n]=sec; w[sec]=0} if(r>w[sec]) w[sec]=r}
       /: (Warning|Critical|ERROR) \[silenced\]$/{if(!(sec in w)){o[++n]=sec; w[sec]=0} z[sec]=1}
       END{split("OK ERROR Warning Critical",t," "); printf "Summary:"; for(i=1;i<=n;i++) printf "%s %s %s%s",(i>1?",":""),o[i],t[w[o[i]]+1],(o[i] in z?" (silenced)":""); print ""}' <<<"$out"
  [[ $silnote ]] && echo "$silnote"
  [[ $out ]] && echo "$out"; echo "RESULT: $v"
fi
exit $rc
