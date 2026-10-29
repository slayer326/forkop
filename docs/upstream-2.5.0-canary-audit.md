# Upstream Forkop X 2.5.0-canary audit (2026-10-27)

Source: https://github.com/Screamshow/forkop-x/releases, 2.5.0-canary.1,
2.5.0-canary.2 and the 2.5.0 release (2026-10-27): the commits after
`bbf1e93f`, where the [2.4.4 audit](upstream-2.4.4-audit.md) stopped. Changes
are adapted selectively, as before; from the 2.5.0 components only
Zapret-Manager is taken.

| Upstream change | Decision |
| --- | --- |
| TorrServer FakeIP connections through sing-box (`83707f17`) | Ported. TorrServer Direct marked every TorrServer socket for bypass, so a tracker that the router DNS answered with a FakeIP address went to the WAN with a 198.18.x.x destination. FakeIP destinations now return before the mark, a rule without them is not active (the worker replaces it), and postinst restarts the worker so an upgrade loads the new module. `tests/torrserver_direct_fakeip.sh`. |
| TorrServer Direct init script in the OpenWrt Makefile (`bcfdb667`) | Ported. Release packages come from `build.sh`, which already installed it; a buildroot package lacked it. |
| Clash API token whenever a secret is set (`1767f1e5`) | Already here: `core/common.uc` `clash_api_secret` drives the controller and every router-side call (`tests/clash_api_auth.sh`). |
| Subscriptions from any HTTPS provider (`ace617b0`) | Not applicable: this fork never had the provider host list. |
| Hysteria2 `pinSHA256` (`61c129ec`) | Not taken now. It extends upstream's certificate-pin handling (`add_certificate_pins`, `tls.certificate_sha256`, skipping cores without pin support), which this fork does not have. Needs the pin support of each core checked first. |
| Feed redirect from any mirror path (`3ec727a1`) | Not needed. Upstream's installer stopped on an unrecognised mirror path; this fork's `mirror-migration.sh` only rewrites official OpenWrt hosts and `pub/software/openwrt`, and leaves any other URL as it is without failing. |
| UTF-8 LuCI bundle (`c414da5f`) | No gain here: our `main.js` holds 23 escaped Cyrillic characters; the translations come from the `.po` files. |
| Drop `flock`, install new dependencies before stopping (`b614b918`) | Not applicable: this fork has no `flock` dependency and no Tailscale scripts that need it. |
| Zapret-Manager web version on install (`c0861b65`, in the 2.5.0 release) | Ported, without its automatic strategy selection. Installing Zapret-Manager activates the web version through the Forkop mirror (only when it is missing or older), writes the mirror launchers `zms` and `zmw` after it, and removal takes the web version and the launchers along, refusing a foreign launcher first. Unlike upstream, Forkop installs no `zmsA`: that launcher exists for the auto-best cron job, which restarts zapret with one strategy after another and rewrites the `NFQWS_OPT` that Forkop manages. Install and every cron refresh remove the `zmsA --auto-best` and `# zm-autobest` jobs. `tests/zapret_manager_web.sh`. |
| Xrust as the default core, Xrust release catalog, Xrust protocol filtering, `android`/`360` → `chrome`, VLESS Encryption and REALITY `pqv` refusals, Xrust cache removal (`b8ed6bcb`, `60fd7369`, `7acb5411`, `589f659a`, `b10216e9`, `09fab917`, `31ba1b67`, `ba6079f4`, `019460a3`, `ee6f8a10`, `e42dfdae`, `f90652e3`) | Not applicable: this fork has no Xrust. Our cores are Tiny, Stable, Extended and podkop-engine; podkop-engine supports VLESS Encryption. |
| ByeDPI removal (`f6d10ef6`, `6c1fac72`) | Not taken: a product decision; ByeDPI stays here. |
| "Same as LuCI" language option removal (`44928e05`) | Not applicable: the language switch was not ported (2.4.4 audit). |
| Unreachable backend helpers (`caaa4b72`), fixture refresh (`42dd49b4`), Beam WRT 1.5.0 canary install (`8e10949a`) | Not taken: upstream-internal cleanup and a platform this fork does not build for. |
