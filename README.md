# smc_ipmi_health.sh

Hardware health check for Supermicro and Intel servers, run from inside the OS.

Any board with a standard IPMI BMC gets most of it; the vendor-specific sensor names and quirks of
Supermicro (X9–X13, H11–H13) and Intel (S2600 family, M50CYP, D50TNP) are handled explicitly.

## What it checks

| Section | Source | Flagged |
|---|---|---|
| System | sysfs DMI, `ipmitool mc info`, `lan print` | model, serials, BIOS, BMC vendor/firmware/IP (channels 1, 8, 3, 2 are tried) |
| Chassis | `ipmitool chassis status`, misc discrete sensors | power/fan/drive fault flags (Critical). Intrusion, redundancy, watchdog and other misc sensors are shown but only Critical-class readings are scored; a latched intrusion sensor is listed, not judged. Healthy misc sensors collapse into one count line |
| Processors | `dmidecode -t processor`, dmesg, CPU discrete sensors | socket not `Populated, Enabled`, machine-check lines, `IERR`/`Thermal Trip`/`Configuration Error`/throttling |
| Memory | `dmidecode -t memory`, EDAC sysfs, memory discrete sensors | per-controller and per-DIMM CE/UE counters, memory thermal-trip sensors |
| Temperatures, Fans, Voltages | `ipmitool sdr elist` (one call) | status `nc`/`lnc`/`unc` → Warning, `cr`/`nr`/… → Critical; thresholds are fetched only for sensors that are not OK |
| Power | `ipmitool dcmi power reading` (or the sum of `PSn Power In`), PSU sensors | AC lost, failure, predictive failure, PSU redundancy |
| Storage | `storcli64`/`perccli64`, `mdadm --detail`, `zpool`, `smartctl --scan-open`, drive-slot sensors | controller status and cache memory errors, VD/PD states, md degraded/recovering, zpool health, SMART health, NVMe critical warning/spare/media errors, ATA reallocated/pending/uncorrectable sectors (named individually), SAS grown defects, SSD wear |
| Network | sysfs, `ip addr` | physical NICs that are up with no carrier **and** either carry an address or belong to a bond/bridge; unplugged spare ports are listed without a verdict |
| GPUs | `lspci`, `nvidia-smi`, dmesg, amdgpu sysfs | GPUs missing from the driver, volatile ECC UE, retired pages / row remap pending or failed, hw/thermal slowdown, PCIe width degradation, NVLink error counters, Xids per GPU (48 63 64 74 79 92 94 95 119 120 are Critical); AMD RAS UE/CE counters |
| SEL | `ipmitool sel info`, `sel elist` | log ≥ 90 % full is a Warning (the BMC stops recording when full); with `--clearsel` the log is archived in full to `SEL_ARCHIVE` and cleared instead; the last five events are printed for context, not judged |

Each tool is optional except `ipmitool`. A missing tool is reported as `ERROR` only when the hardware it
covers is present (a MegaRAID card without `storcli`, NVIDIA GPUs without `nvidia-smi`, no `smartctl` at all).

## Requirements

- Root (the script refuses to run otherwise): `/dev/ipmi0`, `dmidecode`, `smartctl` and `dmesg` need it.
- `ipmitool` with `ipmi_si` + `ipmi_devintf` loaded (`ipmi_ssif` on a few boards).
- Optional: `dmidecode`, `smartmontools`, `pciutils`, `mdadm`, `zfsutils`, `storcli64`/`perccli64`
  (also found under `/opt/MegaRAID`), the NVIDIA driver (`nvidia-smi`), `amdgpu`.
- bash 4+, GNU awk/sed/grep, `timeout`.

## Usage

```
smc_ipmi_health.sh [-q] [-c|--clearsel]

  -q              only print what is not OK; prints nothing at all when healthy
  -c, --clearsel  if the SEL is at least SEL_CLEAR_AT % full, archive it in full and clear it;
                  without this flag a full SEL is reported as a Warning and never touched
```

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `IPMITOOL_OPTS` | empty | extra `ipmitool` arguments, e.g. `-I open`, or `-H bmc -U admin -f pwfile` to query the BMC out of band |
| `TOOL_TIMEOUT` | `60` | seconds allowed per external command (`ipmitool`, `smartctl`, `storcli`, `nvidia-smi`, …) |
| `SEL_CLEAR_AT` | `90` | fill level at which `--clearsel` acts; `0` clears whenever the flag is given |
| `SEL_ARCHIVE` | `/var/log/ipmi-sel` | where the archived logs go, one `sel-<host>-<timestamp>.log` per clear |

Exit codes follow the Nagios convention: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN (not root, BMC
unreachable, or a needed tool is missing and nothing worse was found).

## Output

Every judged line ends in `: OK`, `: Warning`, `: Critical` or `: ERROR`, with the reasons just before the
verdict. The `Summary:` line gives the worst verdict per section. The `RESULT:` line and the exit code are
derived from the same text, so what you see is exactly what was judged.

```
System: Supermicro SYS-1029U-TN10RT SN ..., board X11DPU SN ..., power on, BIOS 3.4 (11/19/2020), BMC Supermicro 1.73 at 10.0.0.12
Summary: chassis OK, processors OK, memory OK, temperatures OK, fans Critical, power Critical, storage Warning, network OK, gpus OK, sel OK
Chassis:
  Cooling/Fan Fault false: OK
  Chassis Intrusion inactive: OK
  3 other discrete sensors: OK
Fans:
  FAN1 6300 RPM: OK
  FAN3 0 RPM (thresholds lnr 300 lcr 500 lnc 700): Critical
Power: 312 Watts in use
  PS2 Status Presence detected, Failure detected, Power Supply AC lost: Critical
Storage:
  AVAGO MegaRAID SAS 9361-8i SN ... fw 4.680.00-8424, status Needs Attention, memory errors 0/0: Warning
    volume 1/1 RAID5 7.276 TB data Dgrd: Warning
    drive /dev/nvme0 SAMSUNG MZQL23T8HCLS-00A07 S64H..., 3% used: OK
RESULT: CRITICAL
```

With `-q` the output is just `hostname VERDICT` followed by the offending lines, which makes it cron-mail friendly:

```
0 * * * * root /usr/local/sbin/smc_ipmi_health.sh -q --clearsel
```

Leave `--clearsel` off if the SEL must only ever be cleared by hand; a full SEL then stays a Warning.

As a Nagios/Icinga/check_mk local check, run it without `-q` and let the plugin framework keep the long output.

## Vendor notes

**Supermicro.** Sensor names follow the usual scheme (`CPU1 Temp`, `P1-DIMMA1 Temp`, `FAN1`…`FANB`,
`PS1 Status`). A failed PSU keeps status `ok` in the SDR and only changes its reading text, which is why
discrete sensors are judged by the `BAD`/`WARN` keyword lists near the top of the script. Empty fan headers
and DIMM slots show as `ns` and are treated as absent. The `Chassis Intru` sensor latches the first time the
lid comes off and stays asserted until cleared in the BMC, so it is reported without a verdict.

**Intel.** The Intel BMC reports CPU and DIMM temperatures as *thermal margins* (`P1 Therm Margin`,
`DIMM Thrm Mrgn 1`): negative numbers are headroom to Tcontrol and are labelled as such. `P1 Status`,
`Mem P1 Thrm Trip`, `PS1 Power In`, `PS Redundancy`/`Fan Redundancy` and the many informational discrete
sensors (watchdogs, buttons, presence) are routed to the right sections; `Non-Redundant`,
`Configuration Error`, `In Critical Array` and friends are classified. Percent/CFM sensors
(`P1 Therm Ctrl %`, `System Airflow`) are judged by their status column. If the BMC has no DCMI power
reading, the `PSn Power In` sensors are summed instead. Intel VMD/VROC/RSTe RAID is md-based: the IMSM
container (`md127`, always *inactive*) is listed without a verdict and the member arrays are judged normally.

## Known gaps and caveats

- Written against stubbed tool output, not against a lab full of boards. Expect a short tuning pass on real
  output, mostly to the `BAD`/`WARN` keyword lists.
- A fan or PSU that was present and is now gone cannot be told apart from an empty header; the SDR simply
  stops reporting it.
- EDAC per-DIMM counters are reported with the EDAC label (`CPU_SrcID#0_MC#0_Chan#0_DIMM#0`), not the
  DMI locator; mapping between the two is platform specific and not attempted.
- The SEL is shown, not classified: the last five entries are printed for context. Memory ECC events
  therefore surface through EDAC and dmesg, not the SEL.
- IPMI has no partial truncate, only `sel clear`, and most BMCs (Supermicro's 512-entry SEL included) stop
  recording once full. With `--clearsel` the script archives the complete log before clearing, verifies the
  dump holds as many entries as the BMC reports, refuses to clear otherwise, and notes each clear in syslog
  (`logger -t smc_ipmi_health`). Without the flag it never writes to the BMC.
- Broadcom HBAs in IR mode (`sas3ircu`) and Adaptec controllers are not parsed; disks behind them still
  appear through `smartctl` if the driver exposes them.
- NVIDIA checks that need a newer driver (row remapping, `clocks_event_reasons`) degrade silently on old
  ones; MIG mode is fine. AMD coverage is what `amdgpu` sysfs exposes (temperature, power, VRAM, RAS counters).
- `ipmitool sdr elist` and `sel` go over the slow KCS interface and take a few seconds each; thresholds
  are fetched only for sensors that are not OK, so a healthy box stays fast.

## Files

- `smc_ipmi_health.sh` — the check
- `README.md` — this file
