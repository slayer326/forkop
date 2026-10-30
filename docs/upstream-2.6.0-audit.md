# Upstream Forkop X 2.6.0 audit (2026-10-30)

Source: https://github.com/Screamshow/forkop-x/releases, 2.6.0-canary.1 and the
2.6.0 release (2026-10-29): the commits after the 2.5.0 release, where the
[2.5.0 audit](upstream-2.5.0-canary-audit.md) stopped. Released in 1.0.64.
Several of these commits are themselves ports from ushan0v/forkop.

| Upstream change | Decision |
| --- | --- |
| Zapret and Zapret2 rule providers and components removed, retired rules become bypass (`a98da8cc`, `59980da5`, `fffa9dd0`, `20380523`, `e36e805b`, `2527b82e`) | Already ported in 1.0.62. |
| A failed version query no longer reverts a good Forkop update (`4fd47951`, `075681dc`, `92b6b40c`) | Ported. `core/packages.uc` is upstream's: `installed-version` keeps found, missing and failed apart and falls back to the opkg status and APK installed databases. `components/action.uc` reads versions through it with two retries; after a package set installed without an error only a version actually read can fail it, and the message names the expected and installed versions. The preflight and recovery checks read through the same helper. `tests/packages_installed_version.sh`, `tests/installer_version_verification.sh`, `tests/forkop_opkg_set.sh`. |
| Reply packets left out of the section capture (`ca943385`) | Ported. `mangle` returns `ct direction reply` right after the DNAT return, `mangle_output` first. `tests/nft_reply_direction.sh`. |
| Routing restored after a network restart (`707e9a8d`) | Ported. `service/lifecycle.uc restore-routing` puts back the rule at 105 and the local routes under the reload lock when the nft table and the core are there, no transition guard is installed and the routing is gone; the core is never restarted. The WAN-up hook asks for it before the start retry, and, unlike upstream, not after an explicit stop. `tests/wan_up_routing_restore.sh`. |
| NTP server names through the bootstrap DNS (`5b2249a4`) | Ported. `tests/sing_box_ntp_bootstrap.sh`. |
| Dashboard latency sweep in batches of four (`48bc5579`) | Ported onto our bounded delay requests (`clash_curl`, `clash_delay_max_time`). `tests/latency_probe_batches.sh`. |
| Dead worker's lock no longer refuses latency tests, owner-less lock window, one lock implementation, pid 0 owner (`3a54ffd1`, `d8be522a`, `a89e2899`, `0a4e662a`) | Already here: `core/runtime_lock.uc` publishes a lock by an atomic rename, waits out the owner-less window, and `busy()` ignores dead owners. |
| LAN traffic with `src_valid_mark` on (`ad9aefe1`) | Not taken now. It only matters while tailscaled runs in netfilter mode, and it adds a router mark, a rule below 105 and changes to the transition guard across about 190 lines of nft code. Needs a router with tailscaled to verify. |
| Compiled bytecode cache for the library (`1cf91cc7`, `5e1c0f0d`) | Not taken now: a speed-up, not a fix, and about 500 lines touching every entry point. |
| Core memory counting Tailscale and TorrServer Direct, services widget names (`9d5c0491`, `6f7a9d04`, `b6c4f9d3`) | Not applicable: the dashboard takes the core's memory from the Clash API, not from procd. |
| Zapret Manager migration to the lightweight ZapretManager_LuCI fork (`686f1d00`, `d816baeb`) | Not taken: the component keeps installing Zapret-Manager through the Forkop mirror (1.0.61). |
| `aarch64_generic` and `mipsel_24kc` Xrust packages, MT7628 catalog (`686f1d00`, `6524eb98`, `e4ba4a64`) | Not applicable: no Xrust. The mirror already serves rockchip/armv8 (`aarch64_generic`) and ramips/mt7621 (`mipsel_24kc`). |
| Beam WRT 1.5.0 canary (`8e10949a`), README, release notes, component column layout, `.gitignore` merge rule (`c42f25be`, `b822240c`, `3000f042`, `920f9fb5`, `d6e187c6`) | Not taken: platforms, documents and layout specific to upstream. |

Also in 1.0.64, not from upstream: on opkg a sing-box variant switch no longer
stops at the dependency dry run when the target only conflicts with the
installed variant (podkop-engine-full declares a conflict with sing-box-tiny).
`tests/sing_box_opkg_variant_conflict.sh`.
