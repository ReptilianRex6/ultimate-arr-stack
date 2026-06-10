# Claude Code Instructions

## NAS Access

SSH credentials are in `.claude/config.local.md`. Read it before running any NAS commands.

## Project Structure

Docker media stack for Ugreen NAS. Edit NAS files (like `pihole/dnsmasq.d/02-local-dns.conf`) **on the NAS**, not locally.

- **Local dev repo**: `/Users/adamknowles/dev/ultimate-arr-stack/`
- **NAS deploy path**: `/volume1/docker/arr-stack/`

## Cross-Stack: Therapy Stack

A separate `therapy-stack` runs at `/volume1/docker/therapy-stack/` on its own network (`therapy-net`, 172.21.0.0/24). Baserow is also on the `arr-stack` network (static IP 172.20.0.20) so Traefik can route to it.

**Files referencing therapy-stack:** `pihole/dnsmasq.d/02-local-dns.conf`, `traefik/dynamic/therapy.local.yml`

**IMPORTANT:** Baserow's static IP (172.20.0.20) is critical. Without it, Docker can assign Gluetun's IP (172.20.0.3) to Baserow on reboot, breaking the VPN stack. The `ip_range: 172.20.0.128/25` in `docker-compose.traefik.yml` confines dynamic IPs to 128-255.

Therapy-stack local repo: `/Users/adamknowles/dev/n8n Therapybot/Git repo/`

## Deploying to the NAS

**The rule (no exceptions): every code change — even a trivial patch image bump — MUST be tested on the NAS and confirmed working BEFORE it is committed or pushed.** There is no "trivial" fast-path that skips NAS testing.

Order, always:

1. Make the change locally.
2. Apply it on the NAS and recreate the affected service(s).
3. **Verify on the NAS:** container healthy, API/UI responds, migration clean, and `npm run test:e2e` where relevant.
4. Only once it's confirmed working on the NAS → commit, then push. (The committed change matches what's already running on the NAS.)
5. If it fails verification → fix or discard. Nothing untested ever reaches git.

Back up a service's config volume before any version bump with a DB migration (`docker run --rm -v <vol>:/src:ro -v <dir>:/bak alpine tar czf /bak/<svc>-config-backup-<stamp>.tgz -C /src .`). Never `docker stop` + ad-hoc `docker run` against a live container's static IP to test — apply the change through compose so the test reflects the real config.

## E2E Tests

Run `npm run test:e2e` after any change to Docker Compose files, service config, networks, or ports. All 13 tests must pass. They screenshot every service UI and verify API responses.
