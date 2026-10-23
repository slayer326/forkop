# Upstream Forkop X 2.4.2–2.4.3 audit (2026-10-23)

Source: https://github.com/Screamshow/forkop-x/releases. Changes are adapted
selectively because this fork has its own mirror, installer, package rollback,
sing-box lifecycle, and UI.

| Upstream change | Decision |
| --- | --- |
| 2.4.2 global subscription update and restored progress | Ported in 1.0.56; the backend already supports an update without a section argument. |
| 2.4.2 mobile connection monitor layout | Deferred: upstream replaces the table markup and over 200 lines of styling. Needs narrow-screen visual verification before a stable release. |
| 2.4.2 URLTest/Priority binding through duplicate and simultaneously renamed nodes | Deferred: requires a persistent filter-bindings format and subscription cache migration. Existing 1.0.54 rename-safe handling remains; porting only the generator would risk changing the selected route. |
| 2.4.3 package index preflight | Ported in 1.0.56 before Forkop service stop. |
| 2.4.3 mobile button and diagnostic value layout | Ported in 1.0.56. |
| 2.4.3 Save & Apply state transition | Already adapted in 1.0.53. |
| 2.4.3 Tailscale mobile UI | Not applicable: native Tailscale/Xrust is not shipped. |

No Tailscale, Xrust, nftables, DNS, or QUIC settings are altered by this release.
