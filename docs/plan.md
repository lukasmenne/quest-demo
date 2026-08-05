# Quest: containerize + multi-cloud deploy + CI/CD

## Context

`quest-demo` is the Rearc Quest, done as an interview take-home. The Express app in
[src/000.js](src/000.js) shells out to six static Go binaries in [bin/](bin/), four of which are
graded checks. I extracted what they actually assert:

| Endpoint | Binary | Passes only if |
|---|---|---|
| `/docker` | `bin/003` | `/.dockerenv` exists on disk |
| `/loadbalanced` | `bin/004` | cloud-specific — see constraint #4 below (not a simple header check) |
| `/tls` | `bin/005` | `X-Forwarded-Proto: https` |
| `/secret_word` | `bin/006` | `SECRET_WORD` env var set |

The load balancer and TLS requirements are therefore not cosmetic — they are verified at runtime
(header inspection for `/tls`, cloud-specific evidence for `/loadbalanced`), and a deployment can
look healthy while still failing them.

Goal: a Dockerfile, a GHCR build/scan pipeline, three cloud deployments (Azure VMSS behind a
Standard Load Balancer with Caddy terminating TLS, AWS ECS Fargate, GCP Cloud Run) each fronted
by a load balancer with real TLS and logging, and a Terraform CI/CD pipeline that plans on PR and
applies on merge.

## Decisions already made

- **No custom domain** — each cloud's built-in managed FQDN provides the trusted cert.
- **Three sibling Terraform modules**, not one polymorphic module (a module cannot span providers).
- **Remote state in Azure Storage**, one state file for all three clouds.
- **SECRET_WORD**: GitHub secret → `TF_VAR_secret_word` → each cloud's secret store → container env.
- **No plan artifact** — plan on PR for review, `apply -auto-approve` on merge. (Revised: the
  earlier gpg-encrypted-artifact flow was dropped as unnecessary complexity.)
- **Trivy scan, non-blocking** (`exit-code: 0`). Findings go to the Security tab via SARIF; no
  PR comment (see Phase 2 — dropped as too bulky, listed there as a future improvement).
- **All three clouds written as first-class now**, though AWS/GCP trials do not exist yet.

## Constraints discovered (these drive the implementation)

1. **`bin/*` are `linux/amd64` static Go binaries.** The image must be single-arch amd64. Do not
   add an arm64 target — the binaries will not run and the checks will fail silently.
2. **`bin/*` are mode `644`.** They need `chmod +x` in the build or every endpoint returns an
   exec error.
3. **`/.dockerenv` is created by the Docker *daemon*, not by containerd.** Azure Container Apps,
   ECS Fargate, and Cloud Run all use containerd — the file will not exist, and `/docker` fails on
   all three clouds despite the app genuinely running in a container. Fix: `RUN touch /.dockerenv`
   in the Dockerfile so it is baked into the image layer.
4. **`bin/004` (`/loadbalanced`) is not a header-presence check — confirmed by disassembly.** It
   loops over the shell-word-split argv fragments of the headers JSON (header values containing
   spaces cause Node's `exec()` to word-split the JSON blob, which is why the binary iterates
   `os.Args` at all) and checks, per cloud:
   - **AWS**: any fragment contains `x-amzn-trace-id` or `elb.amazonaws.com`.
   - **GCP**: a fragment contains both `via:` and `1.1 google`, or both `server:` and
     `google frontend`.
   - **Azure**: headers are irrelevant. It makes a live `GET` to
     `http://169.254.169.254/metadata/loadbalancer?api-version=2021-05-01` (Azure IMDS, 5s
     timeout, `Metadata: True` header) and regex-matches the body against `{"loadbalancer":*`.

   That IMDS endpoint reports the *VM/VMSS instance's* Standard Load Balancer backend-pool
   membership. It is a hypervisor-level feature of Azure VMs (and is exposed to AKS pods by
   default) but **not exposed to Azure Container Apps replicas** — confirmed against Microsoft
   Learn: Container Apps' managed-identity proxy runs on `localhost:12356`, not
   `169.254.169.254`, and there is no documented path from a Container Apps replica to real IMDS.
   Container Apps ingress headers (`X-Forwarded-For`/`-Proto`) satisfy `/tls` but **can never**
   satisfy `/loadbalanced`, regardless of ingress configuration.

   **Decision: switch Azure compute from Container Apps to VMSS + Standard Load Balancer**,
   accepting the added complexity, because it's the only way to genuinely satisfy
   `/loadbalanced` on Azure:
   - The VMSS instances are real backend-pool members of a Standard LB, so IMDS reports
     `{"loadbalancer": ...}` truthfully — no spoofing.
   - Standard LB is Layer 4 only (no TLS, no managed cert), so something else has to terminate
     TLS in front of it with a trusted-CA cert and no custom domain. **This took two revisions,
     both only discoverable by actually applying:**
     1. Azure Front Door (Standard SKU) was the original choice. Rejected outright on Free
        Trial/Student subscriptions (`BadRequest: Free Trial and Student account is forbidden
        for Azure Frontdoor resources`).
     2. Classic Azure CDN (`Standard_Microsoft` SKU) looked like the documented fallback for
        trial subscriptions — until applying it hit `Error: creation of new CDN resources is no
        longer permitted following its deprecation on October 1, 2025`. This is a platform-wide
        retirement, not a subscription restriction, so no account type can create one anymore.
     3. **Final decision**: Caddy runs directly on the VM (via cloud-init) and gets a genuine
        Let's Encrypt certificate for a free wildcard-DNS hostname derived from the LB's public
        IP (`<ip>.sslip.io`, which resolves to that IP with no registration and no propagation
        delay — so there's still no domain to buy or manage). The Standard LB forwards both 80
        (ACME HTTP-01 challenge + redirect) and 443 (the real TLS listener) straight through to
        Caddy; Caddy reverse-proxies to the app container, which is bound to loopback only so it
        can't be reached by skipping Caddy.
   - The VMSS NSG allows inbound on 80 and 443 from `Internet` — Caddy itself is the thing being
     exposed here (there's no separate edge service to lock traffic down to), so this is
     necessarily public, not a shortcut.
5. **The GHCR package must be public.** Cloud Run can only pull private images from Artifact
   Registry / GCR; it cannot hold GHCR pull credentials. Public GHCR also removes the need for
   registry auth in Azure and ECS. (Fallback if it must stay private: mirror the image into
   Artifact Registry as a CD step.)
6. **App port is hardcoded to 3000** in [src/000.js](src/000.js) and paths to `bin/` are relative,
   so `WORKDIR` must be the app root. Leave `000.js` unmodified.
7. **No `package-lock.json` exists** — generate one so `npm ci` is reproducible and Trivy has a
   lockfile to scan.
8. **The first live `apply` (merge to `main`) failed on five independent errors, all specific to
   fresh/trial cloud accounts and only discoverable by actually applying:**
   - Azure: `azurerm_lb_rule` and `azurerm_lb_outbound_rule` sharing one frontend IP requires
     `disable_outbound_snat = true` on the rule, or Azure rejects the outbound rule outright.
   - Azure: the trial subscription has **zero VM quota** for every mainstream x86 SKU/region
     combination checked (`Standard_B1s`/`Standard_D2s_v3`/etc. all `NotAvailableForSubscription`
     in `southcentralus`, `eastus`, `westus2`...). Quota is open in a handful of newer regions
     instead (confirmed via `az vm list-skus --all`) — moved to `denmarkeast`.
   - Azure Front Door forbidden on the trial subscription (see constraint #4) — first switched
     to classic Azure CDN as a fix for this round.
   - Azure: `LoadBalancerProbeHealthStatus` is not a valid diagnostic-setting log category for
     this LB/subscription — dropped from `azurerm_monitor_diagnostic_setting`, kept
     `LoadBalancerAlertEvent` + `AllMetrics`.
   - GCP: a fresh project doesn't have `iam.googleapis.com`, `secretmanager.googleapis.com`, or
     `run.googleapis.com` enabled by default. Added `google_project_service` resources for all
     three, plus a `time_sleep` (30s) before anything that depends on them — newly-enabled GCP
     APIs are known to 403 for a few seconds after the enable call returns.
9. **The classic-CDN fix from constraint #8 turned out to be a dead end too, and the CI plan step
   was silently hiding the error that proved it.** `terraform plan -no-color ... | tee plan.txt`
   has no `pipefail`, so the step's exit code was `tee`'s (always 0), not Terraform's — the PR
   check reported a clean "24 to add, 0 to change, 10 to destroy" plan while the actual `terraform
   plan` process had exited 1 on `Error: creation of new CDN resources is no longer permitted
   following its deprecation on October 1, 2025`, buried in the collapsed plan output. Fixed the
   workflow with `set -o pipefail` so a real plan error fails the check going forward, and
   replaced classic CDN with the Caddy + sslip.io design in constraint #4.
10. **Two more errors surfaced on the next real apply, both only visible once actually applied:**
    - Azure: `denmarkeast` (moved to in constraint #8 for VM quota) doesn't support
      `Microsoft.OperationalInsights/workspaces` at all — confirmed via the resource provider's
      own "available regions" list in the error. No single region has both open `Standard_B1s`
      quota and Log Analytics support (checked programmatically against the full SKU list), so
      the Log Analytics workspace and its Data Collection Rule now live in `eastus` while
      everything else (VNet, LB, VMSS) stays in `denmarkeast`. Cross-region DCR association is
      normal — most real deployments centralize logging from VMs in many regions into one
      workspace.
    - GCP: `google_secret_manager_secret_iam_member` and `google_secret_manager_secret_version`
      both failed with `PERMISSION_DENIED` (`secretmanager.secrets.setIamPolicy` /
      `secretmanager.versions.access`) even though the GitHub Actions service account has
      `roles/editor`. This isn't a missing-API problem like constraint #8's — Secret Manager
      deliberately excludes secret payload access and its own IAM policy management from the
      basic Editor/Owner roles as a security default, for any account. Added
      `roles/secretmanager.admin` to the CI service account's project roles in
      `bootstrap/gcp/variables.tf` (needs a one-time re-apply of `bootstrap/gcp`, same as the
      earlier `bootstrap/aws` re-apply).

## Phase 1 — Dockerfile

Create `Dockerfile`, `.dockerignore`, and commit a generated `package-lock.json`.

```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY src ./src
COPY bin ./bin
RUN chmod +x bin/* && touch /.dockerenv
USER node
EXPOSE 3000
CMD ["node", "src/000.js"]
```

Alpine is safe because the Go binaries are statically linked (verified with `file`). If any turns
out to be dynamically linked against glibc, switch the base to `node:20-slim`.

**Verify locally before touching any cloud:**
```
docker build -t quest:local .
docker run --rm -p 3000:3000 -e SECRET_WORD=<value> quest:local
curl localhost:3000/docker       # expect success, proves the touch worked
curl localhost:3000/secret_word  # expect the word
curl -H 'X-Forwarded-For: 1.2.3.4' localhost:3000/loadbalanced
curl -H 'X-Forwarded-Proto: https' localhost:3000/tls
```

## Phase 2 — `.github/workflows/image.yml`

**On `pull_request`** (paths: `src/**`, `bin/**`, `package*.json`, `Dockerfile`):
build `linux/amd64` with `docker/build-push-action` (`push: false`, `load: true`), scan with
`aquasecurity/trivy-action`, upload SARIF to the Security tab. `exit-code: 0` — informational
only, per your choice.

> **Revised: no sticky PR comment for scan findings.** Originally planned (full table dumped to
> a sticky comment via `marocchino/sticky-pull-request-comment`, truncated to fit GitHub's
> 65,536-char comment limit). Dropped after seeing it live — even truncated, the full-severity
> table is too bulky to be a useful PR comment. Findings are still fully available via the SARIF
> upload to the Security tab. **Future improvement**: a right-sized comment (e.g. HIGH/CRITICAL
> only, or just a count-by-severity summary linking to the Security tab) instead of the raw table.

**On `push` to `main`**: build and push `ghcr.io/lukasmenne/quest-demo` tagged `sha-<short>` and
`latest`. Uses `GITHUB_TOKEN` with `packages: write`.

The package will need to be set public and linked to the repo manually after the first push.

The repo has been renamed `quest-azure` → `quest-demo`, so image and repo names now match. The
local remote still points at the old URL and needs updating as the first implementation step:
`git remote set-url origin https://github.com/lukasmenne/quest-demo.git` (GitHub redirects the old
name, but the OIDC federated-credential subject below must use the new one).

## Phase 3 — Terraform modules

Restructure to three self-contained modules, each owning compute + LB + TLS + logging:

```
terraform/modules/azure/   terraform/modules/aws/   terraform/modules/gcp/
```

The existing [terraform/main.tf](terraform/main.tf) resource group and Log Analytics workspace
move into `modules/azure/` unchanged. [terraform/container_app.tf](terraform/container_app.tf) is
**replaced**, not moved — see constraint #4 above: Container Apps cannot pass `/loadbalanced`, so
the compute resources there are superseded by the VMSS + Standard LB + CDN design in the
Azure section below.

Shared input variables per module: `image`, `secret_word` (sensitive), `app_port = 3000`, `tags`.
Each module outputs `endpoint_url`.

**Azure** — VMSS + Standard Load Balancer, with Caddy on the VM terminating TLS (see constraint
#4 above for why Container Apps was dropped, and constraints #8-9 for why Front Door and then
classic CDN each didn't work out). Compute is a `azurerm_linux_virtual_machine_scale_set` (Ubuntu
22.04, 1 instance, `Standard_B1s`, region `denmarkeast` — see constraint #8) whose NIC is a
genuine backend-pool member of a `azurerm_lb` (Standard SKU) — this is what makes the Azure IMDS
`/metadata/loadbalancer` check truthfully return `{"loadbalancer": ...}`. Cloud-init installs
Docker and runs the image bound to loopback only (`-p 127.0.0.1:3000:3000`, so it's unreachable
except through Caddy) with `--log-driver=journald` (so container stdout lands in the systemd
journal, not the default `json-file` driver which the logging pipeline can't see) and
`-e SECRET_WORD=...`. A throwaway `tls_private_key` supplies the required SSH key for the VMSS
(no real SSH access is intended — cloud-init does all the provisioning). An
`azurerm_lb_outbound_rule` gives the VMSS SNAT'd outbound internet access (no NAT Gateway) so
`apt`/`docker pull`/the Caddy install work; both `azurerm_lb_rule`s set
`disable_outbound_snat = true` since they share the one frontend IP (constraint #8).

The LB is Layer 4 only — no TLS — so cloud-init also installs Caddy from its official apt repo
and writes a two-site `Caddyfile`: a plain `:80` block (serves the app directly and gives Caddy's
automatic-HTTPS machinery a listener for the ACME HTTP-01 challenge) and a block for
`<lb-public-ip>.sslip.io` (sslip.io is a free wildcard DNS service — that hostname resolves to
the embedded IP with zero registration or propagation delay, so there's still no domain to buy).
Caddy provisions and renews a genuine Let's Encrypt certificate for that hostname automatically,
and its `reverse_proxy` directive sets `X-Forwarded-Proto`/`-For` from the real request by
default — no manual header wiring needed the way CDN/Front Door required. The LB has a second
rule/probe pair for port 443 alongside the existing port-80 one (both forwarding straight to
Caddy on the VM; the 443 probe is TCP rather than HTTPS so a brief pre-certificate window can't
flap the backend health). The VMSS NSG allows inbound on 80 and 443 from `Internet` — Caddy
itself is the thing meant to be public here, there's no separate edge service to lock down to.

`SECRET_WORD` is baked into cloud-init (same cleartext-in-state exposure the Container App
`secret{}` block would have had — no change in risk posture). Logging: `AzureMonitorLinuxAgent`
VMSS extension + a Data Collection Rule (Syslog dataSource, since journald-backed) ship container
logs to the existing Log Analytics workspace; `azurerm_monitor_diagnostic_setting` ships LB
metrics/logs there too.

**AWS** — ECS Fargate + ALB + CloudFront. CloudFront supplies the trusted cert on
`*.cloudfront.net` (ACM cannot issue for `*.elb.amazonaws.com`, which is why CloudFront is here at
all) and adds `X-Forwarded-For`. `X-Forwarded-Proto: https` is injected as a CloudFront **origin
custom header**. Logs to CloudWatch via the `awslogs` driver. `SECRET_WORD` in Secrets Manager,
referenced by the task definition's `secrets[]`.

> **Risk — the one thing I cannot verify without an account.** ALB sets `X-Forwarded-Proto` from
> its *own* listener protocol, which is HTTP here. It may overwrite CloudFront's injected header,
> which would fail `/tls`. Verify with `curl <cloudfront-domain>/tls` immediately after the first
> apply. Two documented fallbacks if it fails: (a) swap the ALB for an **NLB** — layer 4, passes
> headers through untouched, so both CloudFront headers survive; (b) add an **nginx sidecar** to
> the task that sets `proxy_set_header X-Forwarded-Proto https` before proxying to 3000.

**GCP** — Cloud Run v2. Its built-in ingress is a Google-managed load balancer with a managed cert
on `*.run.app` and sets both required headers. A Global External ALB is deliberately *not* used —
it would require a domain for a managed cert. `SECRET_WORD` from Secret Manager via
`env.value_source`. Cloud Logging is automatic. A fresh project doesn't come with the IAM, Secret
Manager, or Cloud Run APIs enabled (constraint #8) — `google_project_service` enables all three,
followed by a 30s `time_sleep` before anything that depends on them.

## Phase 4 — `env/dev` wiring

[env/dev/provider.tf](env/dev/provider.tf) gains `aws` and `google` provider blocks alongside the
existing `azurerm`. [env/dev/main.tf](env/dev/main.tf) — currently a broken stub — becomes three
module calls. Add `backend "azurerm"` for remote state.

Because AWS and GCP credentials do not exist yet, each module call is gated by
`enable_aws` / `enable_gcp` (default `false`) using `count`. **This is a deliberate deviation from
"all three fully now":** all three modules are written complete and first-class.

**Gating the module call alone turned out not to be enough — verified empirically.** Terraform has
no way to conditionally skip configuring a *provider* block based on a variable; `provider "aws"`
and `provider "google"` in `env/dev/provider.tf` are configured (their `Configure()` step runs and
resolves credentials) on every `plan`/`apply` regardless of whether any `count`-gated resource
actually uses them. Confirmed locally: with zero AWS/GCP credentials present, `terraform plan`
fails outright on both providers even with `enable_aws`/`enable_gcp` at `false` — exactly the
"breaks the pipeline for Azure too" failure this section already worried about, just from a
different cause than expected (not resource creation — provider `Configure()` itself). Two
different fixes were needed:
- **AWS**: `skip_credentials_validation`, `skip_requesting_account_id`, and
  `skip_region_validation` on the `aws` provider block. Without them the AWS provider makes a live
  `sts:GetCallerIdentity` call during `Configure()`, which fails on placeholder credentials. This
  is unconditional (not tied to `enable_aws`) — once real credentials exist it doesn't hide
  anything, because actual resource creation still fails loudly on bad credentials during `apply`.
- **GCP**: no such flag exists on the `google` provider. It does not validate credentials live at
  `Configure()` time, but does require *some* syntactically well-formed credential to be present
  (confirmed: a placeholder service-account JSON with fake key material satisfies it with zero
  network calls). This means a `GOOGLE_CREDENTIALS` secret — even a placeholder — must exist in CI
  from day one, not just once the GCP trial exists.

Flip `enable_aws`/`enable_gcp` to `true` and swap in real credentials when each trial is live — no
Terraform code changes needed, only the secret values change.

[env/dev/variables.tf](env/dev/variables.tf) gains `image`, `secret_word` (sensitive), the two
enable flags, and AWS/GCP region and project variables.

## Phase 5 — `.github/workflows/terraform.yml`

**On `pull_request`**: Azure OIDC login → `init` → `fmt -check` → `validate` →
`plan -no-color` → parse the add/change/destroy counts → sticky PR comment with the summary and
the plan output. The plan is for **review only** — it is not saved, not uploaded, and not reused.

**On `push` to `main`**: Azure OIDC login → `init` → `apply -auto-approve`. It re-plans against
current state and applies in one step.

> Two consequences of dropping the saved plan, both accepted deliberately:
>
> 1. **No artifact means no cleartext `secret_word` leaving the runner.** The repo is public and
>    Actions artifacts on public repos are downloadable by anyone, so not producing the file is a
>    stronger guarantee than encrypting it. The PR comment still needs `secret_word` redacted —
>    mark the variable `sensitive = true` so Terraform masks it in `plan` output itself.
> 2. **What merges is not provably what was reviewed.** `apply -auto-approve` re-plans at merge
>    time, so any drift or state change between PR and merge is applied without a second look.
>    The saved-plan flow would have failed loudly instead. This is the tradeoff being made for
>    a much simpler pipeline; it is the right call at this scale, with one environment and one
>    person merging.

## Prerequisites you must do outside this repo

Codified as one-time Terraform in `bootstrap/{azure,aws,gcp}/` (each run once, by hand, with
real admin-level credentials — not via the pipeline, which is what these bootstraps exist to set
up in the first place). `bootstrap/azure/` creates the state storage account/container **and**
the GitHub Actions OIDC app registration + federated credentials + role assignments in one pass,
so it must be applied before `env/dev`'s `backend "azurerm"` has anywhere to point.

> **AWS credential gotcha, hit and fixed while first running `bootstrap/aws`:** if `aws sts
> get-caller-identity` works but `terraform plan` fails with `No valid credential sources found` /
> `no EC2 IMDS role found`, check `~/.aws/config` for a `login_session` key. That's the AWS CLI's
> browser-based root login flow (`aws configure login`) — botocore (the CLI) knows how to read its
> cached session, but the Go AWS SDK Terraform's provider uses does not, so it falls through the
> whole credential chain and finds nothing. Fix: `eval "$(aws configure export-credentials
> --format env)"` before running Terraform, which bridges the CLI's session into
> `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars Terraform can read.

1. Azure: `bootstrap/azure` creates the state storage account/container and the app registration
   with federated credentials on subjects
   `repo:lukasmenne@81255942/quest-demo@1322257032:pull_request` and
   `repo:lukasmenne@81255942/quest-demo@1322257032:ref:refs/heads/main` — **the immutable subject
   format** (owner/repo carry their numeric GitHub IDs), not the plain `repo:OWNER/REPO:...` form.
   Confirmed against this repo's actual Azure AD federated-credential UI, which now requires
   Organization ID/Repository ID fields and computes the subject from them. `bootstrap/aws` uses
   the same immutable format in its IAM trust policy; `bootstrap/gcp`'s WIF condition matches on
   the separate `repository` claim instead of `sub`, so it's unaffected either way.
2. GitHub Actions **variables** (`vars`, not secrets — these are identifiers, not credentials;
   OIDC means there's no client secret to protect): `ARM_CLIENT_ID`, `ARM_SUBSCRIPTION_ID`,
   `ARM_TENANT_ID`, `AZURE_TFSTATE_RESOURCE_GROUP`, `AZURE_TFSTATE_STORAGE_ACCOUNT`,
   `AZURE_TFSTATE_CONTAINER` (all from `bootstrap/azure` outputs), plus `AWS_ROLE_ARN` (from
   `bootstrap/aws`) and `GCP_WORKLOAD_IDENTITY_PROVIDER` / `GCP_SERVICE_ACCOUNT` (from
   `bootstrap/gcp`) — `.github/workflows/terraform.yml` already has the AWS/GCP OIDC login steps
   wired in, gated on `vars.AWS_ROLE_ARN`/`vars.GCP_WORKLOAD_IDENTITY_PROVIDER` being non-empty,
   so they activate automatically the moment those variables are set — no workflow changes
   needed when each trial goes live.
3. GitHub **secrets** (actual credential material): `SECRET_WORD`. Also needed **even before the
   AWS/GCP trials exist**, so `terraform plan`/`apply` don't fail configuring those providers
   while `enable_aws`/`enable_gcp` are `false` (see Phase 4): placeholder `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` (any well-formed values — never validated while `enable_aws = false`),
   and a placeholder `GOOGLE_CREDENTIALS` service-account JSON (well-formed JSON with fake key
   material is sufficient — used only until `GCP_WORKLOAD_IDENTITY_PROVIDER` is set, at which
   point the real WIF login step takes over and this is no longer read).
4. After first image push: set the GHCR package public.
5. When trials exist: run `bootstrap/aws`/`bootstrap/gcp` for real, then set the `AWS_ROLE_ARN` /
   `GCP_WORKLOAD_IDENTITY_PROVIDER` / `GCP_SERVICE_ACCOUNT` variables from their outputs and flip
   `enable_aws`/`enable_gcp` to `true`. The placeholder `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
   secrets can stay (harmless placeholders, superseded by the OIDC-assumed role for later steps)
   or be removed.

## Verification

Local Docker checks per Phase 1. Then per cloud, against the module's `endpoint_url` output:

```
curl -s $URL/            # index
curl -s $URL/docker      # exercises the touch /.dockerenv fix
curl -s $URL/secret_word # exercises the secret store wiring
curl -s $URL/loadbalanced
curl -s $URL/tls         # the AWS risk above surfaces here
```

All five must pass on all enabled clouds. `/tls` and `/loadbalanced` are the ones most likely to
fail first, and they fail quietly — check them explicitly rather than trusting a green apply.
