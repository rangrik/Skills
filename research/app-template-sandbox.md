# Generated app template, sandbox runtime, and deployment packaging research

_Date: 2026-05-23. Scope: read-only repository research. No source files were edited; this file is the requested output._

## Executive summary

The generated-app architecture has three overlapping layers:

1. **Legacy/current HTML/Vite + Fastify scaffold (`app-template/`)**: a pnpm workspace with `frontend/`, `backend/`, `shared/`, and OpenAPI generators. The frontend is intentionally thin and delegates almost all platform-owned Vite behavior to `@appsmithorg/template-frontend`; the backend is a Fastify app that registers platform plugins, OpenAPI-driven business routes, a contact-form route, DB/migration startup, and static-site fallback.
2. **Reusable platform packages (`packages/kite-template-*`)**: infrastructure that used to live inside generated apps was extracted into versioned GitHub Packages so existing apps can receive platform fixes by dependency bumps rather than EFS migrations. This is the main maintainability/scalability move.
3. **Next.js transition path (`nextjs-template/` + `nextjs-generation` + E2B PM2 branches)**: new apps can generate per-iteration Next.js project trees under `$EFS_APP_PATH/iter{1,2,3}` and promote one to the per-app workspace root after design selection. During transition, every website is still initially seeded with the Vite `app-template` because sandbox bootstrap requires `frontend/package.json` and `backend/package.json`; Next.js selection overlays the chosen iter at root, and deploy pruning removes legacy Vite-only orphans.

The sandbox runtime is deliberately centralized around **one app directory per generated app (`EFS_APP_PATH`)**, **stable public ports**, **PM2 process supervision**, **Caddy routing**, **zip-based file sync**, and a **single unified metadata proxy** for all sandbox-side coding CLIs. Deployment is Vercel CLI based, with `vercel.ts` acting as the generated app’s per-deployment configuration and branching at build time between Vite/Fastify and Next.js layouts.

## High-value architecture evidence

### 1. Workspace and package boundaries

- Root workspace includes the generated app scaffold and platform packages, but excludes the private script-injector and generated output: `pnpm-workspace.yaml:2-9`.
- `app-template` is itself a pnpm workspace over `backend`, `frontend`, and `shared`: `app-template/pnpm-workspace.yaml:1-4`.
- `app-template/package.json` pins Node/pnpm and drives recursive build/test/typecheck plus OpenAPI codegen:
  - Node/pnpm engines: `app-template/package.json:4-7`
  - package-level scripts: `app-template/package.json:25-30`
  - root dependency on `@appsmithorg/template-shared`: `app-template/package.json:10`
- Runtime package versions currently differ between scaffolds:
  - Vite/Fastify app backend consumes `@appsmithorg/template-backend` `^1.1.1`: `app-template/backend/package.json:41`.
  - Vite frontend consumes `@appsmithorg/template-frontend` `^1.1.3`: `app-template/frontend/package.json:10`.
  - Next.js template still lists `@appsmithorg/template-backend` `^1.0.4`, frontend `^1.1.0`, shared `^1.0.4`: `nextjs-template/package.json:20-22`.
- Published package surfaces:
  - `@appsmithorg/template-backend` exports `file-management`, `contact-form`, `utility`, and `next/kite-platform`: `packages/kite-template-backend/package.json:16-35`.
  - `@appsmithorg/template-frontend` exposes a `kite-client` bin and subpath exports including `./vite`: `packages/kite-template-frontend/package.json:14-38`.
  - `@appsmithorg/template-shared` exports ESM/CJS-compatible `file-management`, `vercel`, and `middleware` subpaths: `packages/kite-template-shared/package.json:16-40`.

### 2. Design principle: platform-owned infrastructure lives in packages, not copied app code

The decision record is explicit: infrastructure was extracted from `app-template/` into independently publishable packages so existing generated apps can receive fixes through dependency version bumps instead of manual EFS patching:

- Decision: `docs/decisions/2026-03-17-extract-platform-packages.md:3-8`.
- Prior problem: only newly created apps got template fixes; existing apps stayed frozen: `docs/decisions/2026-03-17-extract-platform-packages.md:20-26`.
- EFS migration rejected because of slowness and user/platform-code merge conflicts: `docs/decisions/2026-03-17-extract-platform-packages.md:32-39`.
- Publishing workflow publishes in dependency order and then opens an app-template lockfile update PR:
  - package order: `.github/workflows/publish-platform-packages.yml:77-87`
  - publish command: `.github/workflows/publish-platform-packages.yml:109`
  - update app-template package versions and lockfile: `.github/workflows/publish-platform-packages.yml:204`, `.github/workflows/publish-platform-packages.yml:242`.

**Implication:** prefer adding platform/runtime features in `packages/kite-template-*` when they should reach existing apps; use scaffold edits only for files that must physically exist in new app roots.

## `app-template/` architecture and implementation patterns

### Frontend: Vite wrapper with platform plugins

- `app-template/frontend/package.json` has only `kite-client` dev/build scripts and one dependency on `@appsmithorg/template-frontend`: `app-template/frontend/package.json:6-10`.
- `app-template/frontend/vite.config.js` calls `defineKiteConfig` and only adds `kiteBadgeInjector` with app-id/env toggles.
- The real platform Vite config is in `packages/kite-template-frontend/src/vite/base-config.ts`:
  - Auto-discovers every `index.html` under `src/` for MPA support: `base-config.ts:27`, `base-config.ts:91-97`.
  - Adds dev MPA URL rewriting for `/page -> /page/index.html`: `base-config.ts:46`, `base-config.ts:100`.
  - Registers platform plugins (syntax validation, content resolver, HTML validator, analytics, script injection, meta tags, runtime errors, overlay, error logger): `base-config.ts:99-116`.
  - Dev server is stable on port `4321`, proxies `/api/v1` to Fastify `localhost:3001`, disables HMR/websockets, and allows host access in sandbox: `base-config.ts:117-130`.
  - Production output goes to `dist/client`, matching Vercel config and Fastify static serving: `base-config.ts:133-136`.
- `kite-client` is a small bin wrapper around Vite; it strips an accidental `run <cmd>` prefix defensively before execing Vite: `packages/kite-template-frontend/src/kite-client.ts`.

Important frontend plugin patterns:

- **Script injection is dev-only / production-removed**: `script-injector.js` injects `https://assets.appsmith.com/kite_script_injector_v020.js` in dev and strips it in production (`packages/kite-template-frontend/src/vite/integrations/script-injector.js:10-40`).
- **Content resolution for LLM-authored JSON references**: `content-resolver.js` reads `<script id="content" type="application/json">`, resolves string `.json` paths from `content/`, watches them for HMR, and sanitizes raw control characters in JSON strings (`content-resolver.js:18`, `content-resolver.js:88-167`).
- **Build-time JS syntax guardrails**: inline script blocks are parsed with Acorn during production builds and fail the build on syntax errors by default (`js-syntax-validator.js:1`, `js-syntax-validator.js:13-36`, `js-syntax-validator.js:104`, `js-syntax-validator.js:176-177`).
- **Runtime error feedback loop**: runtime errors are captured at `head-prepend`, queued for the dev overlay, and reported to Pirsch in production with spam limits (`runtime-error-capture.js:23-31`, `runtime-error-capture.js:45-76`, `runtime-error-capture.js:89-144`).

### Static HTML prototype pattern

`app-template/docs/prototype-template.html` documents the HTML generation idiom:

- SEO/meta block is required: `prototype-template.html:5`.
- A single JSON content script and in-page router are the required data/routing pattern: `prototype-template.html:196`, `prototype-template.html:263`.
- Route metadata is applied client-side: `prototype-template.html:295`, `prototype-template.html:343`.
- `handleNav` owns client-side navigation: `prototype-template.html:330`, `prototype-template.html:382`.
- Scroll reveal uses `IntersectionObserver`: `prototype-template.html:397`.
- Contact forms call a platform-provided `submitContactForm` if present: `prototype-template.html:444`, `prototype-template.html:460-461`.
- The script injector CDN is included in the prototype template: `prototype-template.html:482`.

### Backend: Fastify composition with OpenAPI as the business-route source of truth

`app-template/backend/src/app.ts` is the main composition root:

- Creates a Fastify app with shared Pino logger options: `app.ts:15`.
- Registers env config and cookies early: `app.ts:18-29`.
- Installs a not-found handler before route/static setup: `app.ts:34`, `app.ts:84-108`.
- Decorates `plugins`, `repositories`, and `services` via factories: `app.ts:36-38`.
- Registers CORS, hooks, sensible, OpenAPI glue, contact-form routes, and static-site serving in that order: `app.ts:42-74`.
- Non-API/non-asset requests fall back to cached page templates for MPA or root `index.html` for SPA: `app.ts:87-108`.

The backend layering pattern is intentionally factory/decorator based:

- `buildPlugins(app)` returns instantiated plugin objects and is typed for Fastify decoration: `app-template/backend/src/plugins/index.ts`.
- `buildRepositories(app)` and `buildServices(app)` start empty with comments instructing where generated entities should register. This makes the extension point explicit while preserving a stable app composition shape.
- Fastify instance type augmentation centralizes `config`, `db`, `plugins`, `repositories`, `services`, and `staticSiteTemplate`: `app-template/backend/src/types/fastify.d.ts:14-20`.

OpenAPI business-route pattern:

- Shared spec is in `app-template/shared/openapi_spec.yaml`; it defines `/health`, `operationId: getHealth`, standard `HealthResponse`/`ErrorResponse`, and `bearerAuth`: `openapi_spec.yaml:1`, `openapi_spec.yaml:6`, `openapi_spec.yaml:10-12`, `openapi_spec.yaml:31`, `openapi_spec.yaml:51`, `openapi_spec.yaml:96`.
- `openapi-glue` locates `shared/openapi_spec.yaml` differently in Vercel vs dev (`process.cwd()` vs parent of backend cwd): `openapi-glue.ts:15-19`.
- Missing/empty specs are skipped gracefully rather than crashing sandbox startup: `openapi-glue.ts:28-39`, `openapi-glue.ts:66`.
- The app registers `fastify-openapi-glue` with `OpenAPIServiceHandlers`, prefix `/api/v1`, and `addEmptySchema` for 204 support: `openapi-glue.ts:51-58`.
- `OpenAPIServiceHandlers` explicitly warns that it is the **only** place to implement business API handlers and not to create manual business route files: `open-api-service-handlers.ts:9`.
- Health probes DB with `SELECT 1` and returns 503 on DB failure: `open-api-service-handlers.ts:22`, `open-api-service-handlers.ts:40-44`.

DB/migrations pattern:

- DB plugin builds a `pg.Pool`, wraps it with Drizzle, initializes a global db factory for repositories, decorates `app.db`, and closes the pool on Fastify close: `db.ts:12-24`.
- Drizzle config writes generated migrations under `src/db/migrations` from `src/db/schema/**/*.ts`: `drizzle.config.ts:6-9`.
- Migration runner skips if `migrations/meta/_journal.json` does not exist, otherwise runs Drizzle migrations with a temporary pool: `migrations.ts:11-41`.
- Startup hook runs migrations on `onReady` and exits the process if they fail: `startup.hook.ts:9-23`.
- Build uses `tsdown`, minification/treeshaking, and copies `src/db/migrations` into `dist/migrations`: `tsdown.config.ts:4-13`.

Static serving pattern:

- Static-site plugin derives `frontend/dist/client` from project root, with Vercel vs dev path differences: `static-site.ts:7-9`.
- It registers `@fastify/static` only if the client build exists: `static-site.ts:31-40`.
- It discovers and caches all `index.html` templates recursively for MPA fallback: `static-site.ts:47-59`.
- It exposes `isEnabled`, `getPageTemplate`, and `getRootTemplate` for the not-found handler: `static-site.ts:17-28`.

### OpenAPI code generation

- `app-template` codegen reads `shared/openapi_spec.yaml`, overwrites `shared/types.ts`, and regenerates `frontend/src/apis`: `openapi-code-scaffolding-generator.ts:15-17`, `openapi-code-scaffolding-generator.ts:22-30`, `openapi-code-scaffolding-generator.ts:37-50`.
- React Query hook generator groups operations by tag, emits an API client from the OpenAPI `servers[0].url`, supports multipart and form-urlencoded helper files, handles binary responses with `responseType: 'blob'`, and builds query keys from operation/path/query params: `hooks-generator.ts:160-164`, `hooks-generator.ts:281`, `hooks-generator.ts:333`, `hooks-generator.ts:474-498`, `hooks-generator.ts:518-536`, `hooks-generator.ts:582-614`.
- Generated API client uses Axios with `withCredentials: true`: `app-template/generators/templates/hooks/api-client.hbs`.

### Vercel packaging for Vite/Fastify apps

- `app-template/api/index.ts` lazily imports `../backend/dist/app.js`, calls `app.ready()`, caches the promise, and bridges Vercel requests into Fastify via `app.server.emit("request", req, res)`: `app-template/api/index.ts:1-17`.
- `app-template/vercel.ts` is dual-layout:
  - Reads `redirects.csv` only if rows exist: `vercel.ts:8-34`.
  - Applies common security headers: `vercel.ts:19-34`.
  - Branches by `existsSync("next.config.js")`: `vercel.ts:43-49`.
  - Next.js gets `framework: "nextjs"`: `vercel.ts:54`.
  - Vite/Fastify gets `framework: null`, `outputDirectory: "frontend/dist/client"`, rewrites `/api/*` and all other requests to `/api`, and includes runtime files for the serverless function: `vercel.ts:59-70`.
- Deployment docs reinforce this: Vercel runs `pnpm install` and `pnpm build`, looks for static output in `frontend/dist/client`, routes API calls through `api/index.ts`, and needs explicit `includeFiles` for runtime-read assets due Vercel tree-shaking: `APP_DEPLOYMENT.md:37-45`, `APP_DEPLOYMENT.md:54-55`, `APP_DEPLOYMENT.md:81-83`.

## Platform package patterns

### `@appsmithorg/template-frontend`

Purpose: centralize generated-site frontend runtime behavior, Vite config, and API utilities.

- Exports `SCRIPT_INJECTOR_CDN_URL` from the root package for Next.js layout reuse: `packages/kite-template-frontend/src/index.ts` and `nextjs-template/src/app/layout.tsx:3`.
- Global API client manager is explicit: `setApiClient()` must be called before APIs use `getApiClient()`, which fails loudly otherwise (`packages/kite-template-frontend/src/utility/api-client.ts`).
- Contact form helper transforms any `HTMLFormElement` into the platform backend payload:
  - default endpoint `/api/v1/contact-form/submit`: `contact-form-submit.ts:3`
  - requires an email field: `contact-form-submit.ts:91-93`
  - builds HTML/text/json bodies and posts with `fetch`: `contact-form-submit.ts:97-119`.
- File-management frontend APIs/hooks use `getApiClient()` plus React Query hooks; this package surface exists, but see the live-surface caveat below: `packages/kite-template-frontend/src/file-management/apis/files.api.ts`.

### `@appsmithorg/template-backend`

Purpose: reusable backend utilities/platform endpoint implementations.

- Contact form service is framework-agnostic and returns a tagged union:
  - Zod schema and body requirements: `packages/kite-template-backend/src/contact-form/service.ts:3-12`
  - `ContactFormOutcome`: `service.ts:39-48`
  - forwards to `PLATFORM_BASE_URL + /api/v1/email/contact-form` with `PLATFORM_API_KEY`: `service.ts:71-76`
  - maps validation/upstream errors into typed error codes: `service.ts:51`, `service.ts:95`.
- Fastify contact form handler maps the service outcome onto Fastify replies: `packages/kite-template-backend/src/contact-form/handlers/contact-form.handler.ts`.
- Next.js dispatcher package routes platform endpoints by an in-library table:
  - route table has `GET health` and `POST contact-form/submit`: `packages/kite-template-backend/src/next/kite-platform/index.ts:20-25`
  - internal `match()` and `dispatch()` return 404 for unknown platform paths: `index.ts:29-57`
  - exported `GET`/`POST` are the intended catch-all re-exports: `index.ts:65-76`.
- File-management package exports Drizzle schema/repo/service/handler/S3 utilities, but it is not wired into the current `app-template/backend/src/app.ts` live route set:
  - service uploads to S3 under `uploads/<uuid>`, stores metadata, signs downloads, deletes S3 + DB: `files.service.ts:29-45`, `files.service.ts:51-57`, `files.service.ts:77`, `files.service.ts:88-98`.
  - repository caps `limit` at 200 and orders by newest created: `files.repo.ts:55-64`.
  - multipart plugin caps uploads to 50MB/file, 10 files, 10 fields: `multipart.plugin.ts:10-19`.
  - S3 wrapper exposes upload, presign, delete, stream: `s3-client.ts:13-23`, `s3-client.ts:41-107`.

### `@appsmithorg/template-shared`

Purpose: shared types and cross-runtime adapters.

- `createVercelHandler()` is a generic Fastify-to-Vercel lazy bridge mirroring `app-template/api/index.ts`: `packages/kite-template-shared/src/vercel/handler.ts:11-30`.
- Prerender middleware identifies bots, skips API/static assets, requires `PRERENDER_TOKEN`, and proxies bots through `service.prerender.io`: `packages/kite-template-shared/src/middleware/vercel-prerender.ts:3-139`.
- File-management shared types live here: `packages/kite-template-shared/src/file-management/types.ts`.

## `nextjs-template/` and Next.js generation architecture

### Template shape

- `nextjs-template/package.json` is a single-project Next.js 16 App Router app on port `4321`, with `pnpm typecheck` as `tsc --noEmit`: `nextjs-template/package.json:11-15`, `nextjs-template/package.json:23-25`.
- `next.config.js` supports two modes:
  - normal Next.js routes for new generation;
  - legacy fallback to `public/prototype.html` if that file exists, with rewrites excluding API/static paths: `nextjs-template/next.config.js:11`, `nextjs-template/next.config.js:30-36`.
- Root layout injects the script-injector only outside production so point-and-click editing is an editing-time capability, not a published-runtime dependency: `nextjs-template/src/app/layout.tsx:19-23`.
- Next middleware is pass-through using `NextResponse.next()` because re-exporting the shared prerender middleware caused Vercel infinite loops for the Next.js pipeline: `nextjs-template/middleware.ts`.
- `nextjs-template/vercel.ts` uses the same marker-based branch as `app-template/vercel.ts`: Next.js lets Vercel auto-detect framework behavior; Vite/Fastify uses explicit output/rewrites/functions.

### Next.js generation skill and per-iteration flow

The current create path for Next.js is skill-driven and deterministic around three scripts:

- Plan copies baked `nextjs-template/` into `$EFS_APP_PATH/<iter>`, fetches visual spec, writes `plan.json` and `images.json`: `backend/app/llm/skills/nextjs-generation/SKILL.md:18`.
- Generate reads the plan, starts image generation in a background thread, runs Gemini to emit files, installs deps, and joins image generation: `SKILL.md:19`, `SKILL.md:107-109`.
- Validate runs `pnpm typecheck`, no Gemini call: `SKILL.md:20`, `SKILL.md:111-117`.
- Only one recovery action is allowed after a failed validation: `SKILL.md:22`, `SKILL.md:141`.
- `plan_files.py` maintains `TEMPLATE_INVARIANTS` so the planner does not re-emit template-owned files: `plan_files.py:51`, `plan_files.py:169`, `plan_files.py:194-205`.
- Image URLs are computed server-side as `{image_base_url}/{slug}.png`, preventing model-authored URL drift: `plan_files.py:183`, `plan_files.py:223`, `plan_files.py:251`.

### Design selection / promotion

- Next.js design selection promotes one iter via `e2b/start-nextjs-main.sh`: it overlays iter contents onto `$EFS_APP_PATH`, installs at root, deletes legacy/draft PM2 processes, starts `nextjs-main` on `4321`, and verifies PM2 status (`start-nextjs-main.sh:59-74`, `start-nextjs-main.sh:79-94`, `start-nextjs-main.sh:99-111`).
- Backend helper `start_nextjs_main()` invokes that script and restarts Caddy: `backend/app/services/e2b_service.py:2628` and `e2b_service.py:2657`.
- Decision rationale: root overlay keeps Vercel publish path simple and downstream tools can keep treating `<app_path>` as project root: `docs/decisions/2026-05-15-nextjs-design-selection-overlay.md`.

## E2B sandbox runtime and execution model

### Image build and installed tools

- E2B image starts from `e2bdev/code-interpreter`, copies active `e2b/` scripts and `nextjs-template/`, runs setup as root: `e2b/Dockerfile:2`, `e2b/Dockerfile:8`, `e2b/Dockerfile:14`, `e2b/Dockerfile:17-23`.
- Setup installs iptables (load-bearing for port firewall), Node 22.17.1, PM2, Claude Code, pnpm 10.14.0, Gemini CLI, agent-browser, Codex, OpenCode pinned to `1.14.51`, Playwright, and axe-core: `e2b/setup.sh:12`, `setup.sh:29`, `setup.sh:42`, `setup.sh:61`, `setup.sh:72`, `setup.sh:80`.
- `/efs` is made world-writable at build time because initial file sync can run before `start.sh` chowns: `setup.sh:125`.
- `sleep` is overridden to fail with an explanatory message, steering agents away from blind waits: `setup.sh:127-136`.

### Bootstrapping a generated app in sandbox

`e2b/start-with-generation.sh` is the main app runtime bootstrap:

- Requires `EFS_APP_PATH`: `start-with-generation.sh:28`.
- Prechecks that app-template scaffold files are visible: root `package.json`, `frontend/package.json`, and `backend/package.json`: `start-with-generation.sh:34-37`. This is why the Vite scaffold remains load-bearing even for Next.js create/design phase.
- Pins `PM2_HOME` so all CLI runners share the same PM2 daemon: `start-with-generation.sh:76-82`.
- Persists `NODE_AUTH_TOKEN` to `.bashrc` for GitHub Packages installs: `start-with-generation.sh:101-104`.
- Emits per-app OpenCode config under `$EFS_APP_PATH/.opencode/opencode.json`: `start-with-generation.sh:111`, `start-with-generation.sh:140-174`.
- Copies `/top/e2b` into the app directory so Caddy/PM2 use app-local configs: `start-with-generation.sh:201-202`.
- Renders Alloy/Loki config for sandbox logs: `start-with-generation.sh:245-319`.
- For pre-selection Next.js apps (`WEBSITE_FRAMEWORK=nextjs`, no `SELECTED_ITERATION`), pre-seeds `iter1..iter3` from `/top/nextjs-template`: `start-with-generation.sh:332-350`.
- Generates PM2 config with `generate-ecosystem-config.mjs`, installs workspace deps, installs per-iter deps with `--ignore-workspace` when needed, then `pm2 start`s the ecosystem: `start-with-generation.sh:356-409`.

Backend `start_sandbox_processes()` pushes the latest scripts into existing sandboxes before running the start script, and injects only bootstrap-needed env vars:

- Uploads `start-with-generation.sh`, `firewall.sh`, `generate-ecosystem-config.mjs`, `start-nextjs-main.sh`, `Caddyfile`, metadata proxy files, and Gemini shim/redirect: `backend/app/services/e2b_service.py:3185-3275`.
- `start_script_envs` includes `EFS_APP_PATH`, application/thread/creator metadata, `PROMTAIL_URL`, `NODE_AUTH_TOKEN`, callback API URL, internal telemetry token, `WEBSITE_FRAMEWORK`, and `SELECTED_ITERATION`: `e2b_service.py:3307-3331`.
- It explicitly does **not** inject master LLM/cloudinary/gallery secrets into PM2 bootstrap, and comments require any new PM2 child secrets to be added to `blockedSecrets`: `e2b_service.py:3307-3331`.
- Start script timeout is 10 minutes; missing generated files returns exit code 64 and gets one backend-side rehydrate retry: `e2b_service.py:68`, `e2b_service.py:1406`, `e2b_service.py:3346-3359`.

### PM2 process topology

`e2b/generate-ecosystem-config.mjs` emits process config from environment:

- It shadows sensitive env vars for all public/non-proxy processes via `blockedSecrets`: `generate-ecosystem-config.mjs:36-48`.
- Always includes legacy Vite/Fastify preview services: `frontend` (`cwd=$EFS_APP_PATH/frontend`) and `backend` (`cwd=$EFS_APP_PATH/backend`): `generate-ecosystem-config.mjs:50-67`.
- Includes `caddy`, `alloy`, `pm2-events`, and `metadata-proxy`: `generate-ecosystem-config.mjs:73-123`.
- Next.js boot branches by `SELECTED_ITERATION`:
  - unset: emit `nextjs-iter1..3` on ports 4501-4503 if iter `package.json` exists;
  - set: require root `package.json`, emit only `nextjs-main` on 4321.
  Evidence: comments and branch at `generate-ecosystem-config.mjs:128-155`, `generate-ecosystem-config.mjs:155-196`.
- Next.js PM2 entries use bounded autorestart (`max_restarts: 2`, `min_uptime: 10000`): `generate-ecosystem-config.mjs:147-154`, `generate-ecosystem-config.mjs:176-177`, `generate-ecosystem-config.mjs:195-196`.

### Caddy routing and preview URLs

- Public `:8080` blocks Vite `/@fs/*`, routes `/api/*` to Fastify `:3001`, and everything else to frontend/Next `:4321`: `e2b/Caddyfile:10-13`.
- Iteration preview servers `:4401-:4403` first serve static HTML prototypes from `docs/<iter>/prototype/index.html`, otherwise proxy to Next.js iter dev servers `:4501-:4503`: `e2b/Caddyfile:24-52`.
- Frontend derives iteration URLs by swapping the port prefix on the sandbox URL (`iter1=4401`, `iter2=4402`, `iter3=4403`): `frontend/src/pages/AppDetails/utils/prototypeUrl.ts:1-17`.
- Preview state fetches app/draft sandbox URLs, computes selected design URLs from app-state events, and prefers draft sandbox data when editing a draft: `frontend/src/pages/AppDetails/contexts/PreviewStateContext/context.tsx:212-228`, `context.tsx:284-302`, `context.tsx:341-349`.

### Unified metadata proxy and sandbox security

- `e2b/metadata_proxy.py` is the single proxy for Claude Code, OpenCode, Codex, and Gemini. It strips `s/<node>/<workflow>/<message>` URL metadata into traces, selects OpenRouter vs Google vs local token-count estimator, pins `anthropic/*` provider order, and posts telemetry: `metadata_proxy.py:2-26`.
- It serves `/v1/messages/count_tokens` locally with a chars/3.5 estimator so `ANTHROPIC_API_KEY` does not need to live in the sandbox: `metadata_proxy.py:26-43`, `metadata_proxy.py:87-93`, `metadata_proxy.py:179-219`, `metadata_proxy.py:601-602`.
- Gemini CLI traffic is intercepted with a PATH shim + `NODE_OPTIONS=--import` fetch monkey patch because Gemini CLI hardcodes Google’s base URL: `e2b/gemini_proxy_shim.sh`, `e2b/gemini_proxy_redirect.mjs`.
- `firewall.sh` inserts loopback allow and catch-all drop rules for metadata proxy port `8787`, logging warnings but not aborting startup on iptables failures: `e2b/firewall.sh:28-46`.
- QA assets are copied into old sandboxes idempotently before QA runs: `backend/app/services/e2b_service.py:3059`.

### File sync and per-app runtime persistence

- New sandboxes are created with metadata including application/thread/host/creator/sandbox role and a `template_version` stamp when configured: `backend/app/services/e2b_service.py:638-648`, `e2b_service.py:792`, `e2b_service.py:116`.
- On resume, stale `template_version` mismatches cause the sandbox to be killed/recreated: `e2b_service.py:606`, `e2b_service.py:643`.
- Sandbox URLs are normalized through a proxy domain if configured and always materialized as `https://...`: `e2b_service.py:166-212`, `e2b_service.py:696-723`.
- New sandbox creation ensures local website initialization, then syncs files to the sandbox before running the start script; this avoids races where the start precheck cannot see app files: `e2b_service.py:1123-1150`.
- Sync to sandbox packages files into an in-memory zip, writes it to `/var/tmp/_sync_files_*.zip`, unzips to `/`, removes the zip, and initializes/commits a git repo for future diffs: `backend/app/services/sync_files_service.py:438-469`, `sync_files_service.py:523`, `sync_files_service.py:547-576`.
- Sync exclusion constants hide dependencies/build caches/logs/security files; `.next/**` is excluded both directions to avoid massive cache syncs: `backend/app/constants/generated_website_constants.py:25-26`, `generated_website_constants.py:103-104`.

## Deployment packaging and lifecycle

### Backend container packaging

The platform backend Docker image copies the app templates and E2B scripts into `/top` alongside backend code:

- Vercel CLI and pnpm are installed in the platform image: `Dockerfile:54-57`.
- `app-template`, `nextjs-template`, and `e2b` are copied into the runtime image: `Dockerfile:75-77`.

### Website directory initialization

`website_service.ensure_website_initialized()` seeds every website directory from the Vite `app-template`, even Next.js apps:

- Early-return if scaffold-required files already exist: `backend/app/services/website_service.py:1227`.
- Required files are root `package.json`, `frontend/package.json`, and `backend/package.json`: `website_service.py:454-458`.
- Comment documents the transitional reason: HTML apps use the scaffold as runtime; Next.js apps need it as placeholder sandbox runtime until selection overlays a Next.js iter: `website_service.py:1230-1245`.
- Copy uses `_copy_if_missing` to avoid overwriting real/generated content: `website_service.py:1213-1215`, `website_service.py:1252`.
- Env files are written to root `.env` for Next.js markers or `backend/.env` for Vite/Fastify, with `PLATFORM_BASE_URL`, `PLATFORM_API_KEY`, and `PRERENDER_TOKEN`: `website_service.py:1270-1277`.

### Vercel deployment flow

- `APP_DEPLOYMENT.md` explains the generated app deploy API invokes Vercel CLI, links a Vercel project via `.vercel/project.json`, and usually runs `vercel --prod --no-wait`: `APP_DEPLOYMENT.md:19-45`.
- `_link_project()` links by project ID (not derived name) to avoid cross-owner name collisions: `backend/app/services/vercel_deploy_service.py:944-1018`.
- `_prepare_for_deployment()` is the centralized pre-deploy hook:
  - syncs `vercel.ts`, removes stale `vercel.json`: `vercel_deploy_service.py:1259-1289`;
  - prunes legacy Vite scaffold from Next.js roots: `vercel_deploy_service.py:1292`, `vercel_deploy_service.py:1310-1329`;
  - regenerates lockfile: `vercel_deploy_service.py:1294`, `vercel_deploy_service.py:1130`.
- Legacy Vite scaffold paths pruned for Next.js deploys are `api`, `frontend`, `backend`, `shared`, `generators`, and `pnpm-workspace.yaml`: `vercel_deploy_service.py:1310-1317`.
- Deploy command uses `vercel deploy --prod --yes`, adds `--no-wait` by default, optionally passes build env vars, and retries transient CLI/API issues: `vercel_deploy_service.py:1369-1396`.
- Lockfile regeneration uses `pnpm install --lockfile-only`, isolates Corepack home, passes `NODE_AUTH_TOKEN` for GitHub Packages, and uses pod-local pnpm store inside `/top`: `vercel_deploy_service.py:1130-1206`.

### CI packaging

- E2B template workflow rebuilds on `e2b/**`, `nextjs-template/**`, or workflow changes; it sets template/team IDs and runs `e2b template build`: `.github/workflows/e2b-template.yml:13-15`, `e2b-template.yml:78-81`.
- That workflow notes backend template-version convergence via the last commit touching `e2b/` or `nextjs-template/`: `.github/workflows/e2b-template.yml:84-87`.

## Maintainability/scalability patterns to preserve

1. **Put shared platform behavior in versioned packages.** This is the explicit strategy for avoiding per-app EFS migrations and conflicts with user-edited app code (`docs/decisions/2026-03-17-extract-platform-packages.md:26-39`).
2. **Keep generated app roots small and declarative.** `app-template/frontend` delegates to `defineKiteConfig`; `backend` delegates platform helpers to `@appsmithorg/template-backend`; OpenAPI spec/types are generated rather than hand-synchronized.
3. **Use one source of truth for routing per stack.** Fastify business routes are OpenAPI operation IDs handled by `OpenAPIServiceHandlers`; Next.js platform routes are intended to live under a reserved `kite-platform` dispatcher.
4. **Make sandbox boot deterministic and self-healing.** `start-with-generation.sh` prechecks required files, regenerates PM2 config, installs deps, pre-seeds Next.js iters, and starts all processes from one generated ecosystem config.
5. **Keep public app processes secret-poor.** Bootstrap env is audited, PM2 children get `blockedSecrets`, metadata proxy receives renamed telemetry token, Anthropic count_tokens is local, and port 8787 is firewalled.
6. **Use marker-file branching for layout compatibility.** `next.config.js` is the layout marker in `vercel.ts`, middleware/env-file selection, deploy pruning, and hijack/deployment flows. This allows Vite/Fastify and Next.js apps to coexist during migration.
7. **Use stable port conventions.** `3001` Fastify, `4321` frontend/Next main, `8080` public Caddy, `4401-4403` iteration previews, `4501-4503` Next iter dev servers, `8787` metadata proxy.
8. **Validate with deterministic scripts, not agent judgment.** OpenAPI codegen, JS syntax validation, Next.js `plan/generate/validate`, typecheck preflight, and Vercel lockfile regeneration reduce LLM drift.
9. **Treat Vercel runtime reads explicitly.** `vercel.ts` `includeFiles` is mandatory for YAML/static assets because Vercel tree-shakes serverless functions (`APP_DEPLOYMENT.md:45`, `APP_DEPLOYMENT.md:83`).

## Risks, drift, and open discrepancies found

1. **Next.js platform-route decision is not fully reflected in checked-in `nextjs-template`.**
   - Decision says the template should have `src/app/api/v1/kite-platform/[...path]/route.ts` re-exporting `@appsmithorg/template-backend/next/kite-platform`: `docs/decisions/2026-05-21-nextjs-platform-routes-via-library-dispatcher.md:5`, `:30`.
   - The package export and dispatcher exist: `packages/kite-template-backend/package.json:33-35`, `packages/kite-template-backend/src/next/kite-platform/index.ts:20-76`.
   - Current `nextjs-template/src/app/api/v1` only has `health/route.ts` (`route.ts:1-2`), and the expected catch-all file is absent in this checkout.
   - Related drift: decision says `TEMPLATE_INVARIANT_PREFIXES` protects `kite-platform/**` in `plan_files.py` (`docs/...dispatcher.md:21`, `:32`), but current `plan_files.py` only has exact `TEMPLATE_INVARIANTS` (`plan_files.py:51-205`).
   - Next.js template also depends on `@appsmithorg/template-backend` `^1.0.4` (`nextjs-template/package.json:20`) while the dispatcher package version is `1.1.1` (`packages/kite-template-backend/package.json:3`).
2. **Deployment comment/code mismatch for `vercel.ts` source.** `_prepare_for_deployment()` doc says sync from `nextjs-template`, but code copies `get_app_template_dir() / "vercel.ts"`: `vercel_deploy_service.py:1263-1265` vs `vercel_deploy_service.py:1281-1284`. The two files are currently equivalent in intent, but the comment can mislead future edits.
3. **File-management package is a dormant surface.** Backend/frontend/shared file-management code exists, but `app-template/backend/src/app.ts` does not register `FilesHandler`. Decision record explicitly says this is intentional until a real caller exists: `docs/decisions/2026-05-21-nextjs-platform-routes-via-library-dispatcher.md:7`, `:25`.
4. **Vite scaffold remains load-bearing for Next.js boot.** `start-with-generation.sh` requires `frontend/package.json` and `backend/package.json` even for Next.js apps (`start-with-generation.sh:34-37`), and `ensure_website_initialized()` seeds Vite scaffold for every website (`website_service.py:1230-1245`). Changes that remove or move these files can break Next.js sandbox boot before generation starts.
5. **Middleware/prerender split differs by stack.** `app-template/middleware.ts` re-exports shared prerender middleware, while `nextjs-template/middleware.ts` is pass-through because shared middleware caused Vercel loops. Any prerender fix should be tested specifically against Next.js middleware semantics.
6. **Multiple copies of E2B scripts exist.** Active runtime scripts are root `e2b/` and are copied into backend image/E2B image. `packages/kite-template-backend/src/e2b/*` appears older and is not part of `tsup` exports; avoid assuming package-local e2b scripts are active without tracing the build.

## Quick mental model for future changes

- **Changing generated-site frontend runtime behavior?** Prefer `packages/kite-template-frontend` and publish/bump. Only edit `app-template/frontend`/`nextjs-template` when a physical file must exist in the scaffold.
- **Changing generated-site backend platform endpoints?** For Fastify HTML apps, use `@appsmithorg/template-backend` and register through `app-template/backend/src/app.ts` only when live. For Next.js platform endpoints, intended architecture is one reserved catch-all dispatcher under `kite-platform`.
- **Changing Next.js generation?** Update `nextjs-template`, `backend/app/llm/skills/nextjs-generation/*`, and E2B template build path together; remember E2B image bakes `/top/nextjs-template`.
- **Changing sandbox runtime?** Root `e2b/` plus `backend/app/services/e2b_service.py` startup file map must stay in sync; existing sandboxes are refreshed by backend writes but new images require E2B template rebuild.
- **Changing deploy behavior?** Update `vercel.ts` and `vercel_deploy_service._prepare_for_deployment()` together; for Next.js, account for legacy Vite scaffold pruning.
