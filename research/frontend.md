# Frontend product app architecture research

Scope: evidence-backed architecture review of `frontend/` only. No source files were changed while researching.

## Executive summary

The frontend product app is a Vite + React 19 TypeScript app built around TanStack Router, TanStack Query, Zustand, Tailwind v4 semantic tokens, Radix/shadcn-style UI primitives, MSW-backed tests/mocks, and several iframe postMessage bridge capabilities. The major architectural boundary is:

- `src/routes.tsx` owns centralized route configuration, auth guards, search-param validation, and nested `AppDetails` routes.
- `src/data/*` owns typed API calls, query/mutation hooks, MSW handlers, factories, and entity-specific real-time cache handlers.
- `src/pages/*` owns route components and page-specific orchestration/state; `AppDetails` is the main product surface and composes multiple context providers.
- `src/components/*` owns reusable UI primitives/layout components.
- `src/lib/*` owns shared integrations, analytics, iframe bridges, auth/API helpers, hooks, and utility code.

The architecture is generally scalable through typed routes, query-key factories, entity data folders, page-local Zustand stores, and context decomposition. The main maintainability risks are (1) drift between docs and code style, (2) a central `routes.tsx` that continues to grow, (3) SSE parser/handler/type mismatches, and (4) iframe bridge use of broad `postMessage('*')` requiring careful trust-boundary review.

## Codebase guide and local conventions

### Frontend-wide `agents.md`

`frontend/agents.md` establishes the intended style baseline:

- concise TypeScript, SOLID, functional/declarative style, flat code, early returns, explicit parameters, and named exports (`frontend/agents.md:7-15`);
- no `any`, interfaces for props, strict TypeScript, and const maps instead of enums (`frontend/agents.md:16-32`);
- named effect functions, verb-led function names, and handler naming conventions (`frontend/agents.md:43-67`);
- API/JSON parsing should use try/catch, global error boundaries, and if-return style (`frontend/agents.md:69-84`);
- accessibility expectations: semantic HTML, ARIA labels/roles, and keyboard testing (`frontend/agents.md:86-92`);
- Tailwind v4 usage with no inline styles and semantic-token-only color usage (`frontend/agents.md:111-124`);
- surface/background/foreground token decision rules and Analytics/Discoverability visual guardrails (`frontend/agents.md:135-215`).

Observed drift to be aware of:

- `APIError.details`, `extractErrorMessage`, and API request bodies still use `any` in `src/lib/api.ts` (`frontend/src/lib/api.ts:17-21`, `frontend/src/lib/api.ts:35-36`, `frontend/src/lib/api.ts:226-247`).
- `DeploymentStatus` is an enum, while the guide prefers const maps (`frontend/src/data/Application/types.ts:135-142`).
- `AppBottomNavigation` still uses hardcoded orange utility classes instead of semantic tokens (`frontend/src/pages/AppDetails/components/Navigation/AppBottomNavigation.tsx:88-96`, `frontend/src/pages/AppDetails/components/Navigation/AppBottomNavigation.tsx:125-128`).

### Directory-specific guides

- `src/components/agents.md` separates global reusable UI from page-specific components and says global components should be generic, configurable, business-logic-free, styled consistently, and have Storybook coverage (`frontend/src/components/agents.md:7-25`). It also defines responsive interaction patterns: desktop popover/modal vs mobile bottom sheet/fullscreen sheet (`frontend/src/components/agents.md:91-200`).
- `src/data/agents.md` defines the entity-folder pattern: `api.ts`, `queries.ts`, `types.ts`, `transformers.ts`, `utils.ts`, `factories.ts`, and `handlers.ts` (`frontend/src/data/agents.md:5-19`, `frontend/src/data/agents.md:42-52`, `frontend/src/data/agents.md:84-93`, `frontend/src/data/agents.md:159-209`).
- `src/pages/agents.md` states routes live centrally in `src/routes.tsx`, route components live under `src/pages`, and page-local Zustand stores belong under `src/pages/[PageName]/stores` (`frontend/src/pages/agents.md:5-21`, `frontend/src/pages/agents.md:45-61`). It also recommends loaders/query params for URL state and Zustand for complex UI state (`frontend/src/pages/agents.md:129-171`).

## Runtime, build, and top-level app shell

### Package/config stack

- Scripts include `dev`, MSW-backed mock dev, `typecheck`, `build`, lint, Vitest, coverage, Playwright E2E, theme generation, and Storybook (`frontend/package.json:10-27`).
- Core dependencies include React, TanStack Query/Router/Table, Radix UI packages, Tailwind v4, Zustand, Sonner, PostHog/Mixpanel, Faro, and iframe/content tooling (`frontend/package.json:34-112`).
- Vite uses a custom grab-bridge plugin before React, Tailwind v4 plugin, bundle visualizer, Faro source-map upload, `@` alias, API proxy, production `/templates/` base, manual chunks for React/router/query, and explicit font asset handling (`frontend/vite.config.js:14-43`, `frontend/vite.config.js:47-58`, `frontend/vite.config.js:60-110`).
- TypeScript strict mode is enabled with bundler module resolution and `@/*` path alias (`frontend/tsconfig.json:2-19`).
- ESLint enforces TanStack route property order, import order, unused imports, Prettier, React hooks exhaustive deps, and a restricted loader-icon import pattern (`frontend/eslint.config.js:30-99`).

### Boot sequence

`src/main.tsx` creates the shared `QueryClient`, configures query defaults, optionally starts MSW, exposes E2E test helpers, and renders the router:

- query defaults: five-minute stale time, ten-minute gc time, no retry on 4xx `APIError`, one retry otherwise, no refetch-on-window-focus (`frontend/src/main.tsx:12-34`);
- MSW is enabled only when `VITE_MSW === 'true'`; when enabled it exposes `publishChatEvent`, the worker, `http`, `HttpResponse`, and the shared query client on `window.__testHelpers` (`frontend/src/main.tsx:36-55`);
- the app renders `QueryClientProvider` + `RouterProvider` with the shared query client in router context (`frontend/src/main.tsx:58-72`);
- web vitals initializes after render setup (`frontend/src/main.tsx:74-75`).

`src/App.tsx` is the root route component and app shell:

- wraps the route outlet in Faro error boundary, Helmet provider, and `next-themes` (`frontend/src/App.tsx:29-50`);
- runs tracking hooks from current user state (`frontend/src/App.tsx:19-24`);
- conditionally renders Betterbugs, Pylon chat, and credit recharge only for authenticated users (`frontend/src/App.tsx:26-48`);
- always renders the `Outlet`, Sonner toaster, and CSS debugger (`frontend/src/App.tsx:40-46`).

## Routing and authentication

Routing is centralized in `src/routes.tsx` and matches the page guide.

### Route context and auth guard

- The router context carries a `QueryClient` (`frontend/src/routes.tsx:46-48`).
- `layoutBeforeLoad` fetches the current user through React Query, swallows network/server errors so the layout can render error UI, and redirects anonymous users to a WorkOS login URL preserving path/search/hash (`frontend/src/routes.tsx:50-85`).
- The root route uses `App`; protected layout uses `DefaultLayout` and `layoutBeforeLoad` (`frontend/src/routes.tsx:87-98`).
- `getLoginUrl` fetches `/api/v1/auth/workos/login-url?next=...` and falls back to `/api/v1/auth/workos/login` (`frontend/src/lib/auth.ts:1-26`); `redirectToLogin` sets `window.location.href` (`frontend/src/lib/auth.ts:28-34`).
- `ApiClient` also redirects on 401, with a static `isRedirecting` guard to prevent repeated redirects (`frontend/src/lib/api.ts:91-131`).

### Route tree and search params

- Top-level protected routes include `/`, `/new`, `/apps`, `/billing`, `/trial-downgrade`, `/merge`, `/invite/$token`, and `/discovery` (`frontend/src/routes.tsx:100-121`, `frontend/src/routes.tsx:350-398`).
- `AppDetails` is nested under `/app-details/$appId`; its search validates optional `draftId` (`frontend/src/routes.tsx:123-138`).
- App detail child routes include preview, design, drafts, code, content/collections/storage, data, analytics/leads/discoverability, settings, and a catch-all redirect (`frontend/src/routes.tsx:140-348`, `frontend/src/routes.tsx:428-449`).
- Search validators normalize preview `prompt`/`path`, code/content/data query params, billing upgrade state, and discovery framework (`frontend/src/routes.tsx:159-172`, `frontend/src/routes.tsx:230-298`, `frontend/src/routes.tsx:350-398`).
- Router defaults include intent preloading, five-second default stale time, and scroll restoration (`frontend/src/routes.tsx:457-467`).

### Feature-gated routes

- Drafts are gated by backend-provided `viewer_role`, intentionally not by the caller's PostHog flag (`frontend/src/routes.tsx:180-221`).
- Code route preloads feature flags and redirects if `release_code_tab_enabled` is false (`frontend/src/routes.tsx:230-251`).
- `/app-details/$appId/discoverability` redirects to `/app-details/$appId/analytics/discoverability` preserving search/hash (`frontend/src/routes.tsx:330-342`).

### Route tests

`routes.test.tsx` directly tests `layoutBeforeLoad` and `draftsBeforeLoad` with MSW:

- anonymous redirect and full next URL preservation (`frontend/src/routes.test.tsx:34-78`);
- authenticated/no-network redirect behavior (`frontend/src/routes.test.tsx:80-99`);
- drafts access for owner/collaborator and redirect when `viewer_role` is absent (`frontend/src/routes.test.tsx:102-154`).

## API and data layer

### API client

- `ApiClient` defaults to `VITE_API_BASE_URL || '/api/v1'` and always sends `credentials: 'include'` plus JSON content type (`frontend/src/lib/api.ts:9-10`, `frontend/src/lib/api.ts:91-103`).
- Error extraction supports FastAPI `detail` as string, object, or validation-array shape, with `message` fallback (`frontend/src/lib/api.ts:30-64`).
- 402/426 responses open the credit/upgrade recharge dialog; 500 errors are normalized to `Internal Server Error`; non-expected API errors are pushed to Faro with endpoint/method/status/app/request id context (`frontend/src/lib/api.ts:132-190`).
- Network/non-API errors are pushed to Faro and logged before rethrow (`frontend/src/lib/api.ts:193-210`).

### Entity folder examples

`Application` is the clearest data-layer example:

- `api.ts` centralizes endpoint constants and wraps raw calls in typed async functions with try/catch and transformations (`frontend/src/data/Application/api.ts:26-41`, `frontend/src/data/Application/api.ts:49-94`, `frontend/src/data/Application/api.ts:139-165`).
- `queries.ts` centralizes query keys and query/mutation hooks (`frontend/src/data/Application/queries.ts:48-57`). `useApps` uses infinite query pagination (`frontend/src/data/Application/queries.ts:60-74`); `useAppSandbox` opts into zero stale/gc, periodic refetch, and no retries for sandbox freshness (`frontend/src/data/Application/queries.ts:76-89`); `useApp` seeds detail data from the apps-list cache (`frontend/src/data/Application/queries.ts:101-120`).
- Mutations update/invalidate related caches; `useCreateApp` hydrates app, app-thread, latest thread, and checkpoints caches to avoid loading flicker after creation (`frontend/src/data/Application/queries.ts:122-181`).
- Types model backend responses plus UI display extensions, sandbox URL contracts, collaborator metadata, and deployment status (`frontend/src/data/Application/types.ts:18-74`, `frontend/src/data/Application/types.ts:111-153`).
- MSW handlers and factories live with the entity and simulate list/create/detail/deployment flows (`frontend/src/data/Application/handlers.ts:18-71`, `frontend/src/data/Application/handlers.ts:101-180`, `frontend/src/data/Application/factories.ts:12-40`, `frontend/src/data/Application/factories.ts:81-102`).

Other patterns:

- `FeatureFlags` caches access flags indefinitely and fails closed for `useCanAccessFeature` (`frontend/src/data/FeatureFlags/queries.ts:15-39`, `frontend/src/lib/hooks/useCanAccessFeature.ts:3-26`).
- `User` uses `fetchMe` at `/auth/workos/user`, while logout/login URLs are absolute `/api/v1/...` paths (`frontend/src/data/User/api.ts:5-20`, `frontend/src/data/User/api.ts:22-37`). `useMe` disables retry, sets stale/gc to zero, and avoids mount/window-focus refetch (`frontend/src/data/User/queries.ts:12-23`).
- Some newer/simple data modules use ad hoc query keys (`Analytics` uses `['analytics-stats', appId, params]`; `Discoverability` defines a query-key object) (`frontend/src/data/Analytics/queries.ts:11-20`, `frontend/src/data/Discoverability/queries.ts:12-33`). For scalability, prefer explicit query-key factories consistently.

## SSE, chat events, and cache synchronization

### Sending messages and streaming

- `sendChatMessage` posts to `/chat/message` with `application_id`, `thread_id`, user message, attachments, DOM-element chips, edit type, and current page path (`frontend/src/data/Chat/api.ts:28-55`). It normalizes backend responses into queued vs direct send results (`frontend/src/data/Chat/api.ts:57-81`).
- `streamAppChat` creates an `EventSource` at `/api/v1/chat/$appId`, optionally with `last_event_timestamp` and `thread_id` query params (`frontend/src/data/Chat/api.ts:399-429`). It registers handlers for a fixed list of SSE event types and closes on `done` (`frontend/src/data/Chat/api.ts:450-476`).
- SSE parsing stamps backend `thread_id` into parsed events so active-thread guards can prevent draft bleed (`frontend/src/data/Chat/api.ts:124-135`).

### Event bus and deduplication

- `chatEventBus` is a small pub/sub abstraction with type-specific subscriptions (`frontend/src/data/Chat/chatEventBus.ts:11-47`).
- It also tracks locally sent messages for one-minute echo suppression keyed by `senderId:content`, with `markMessageSent`, `unmarkMessageSent`, and `wasMessageSentLocally` (`frontend/src/data/Chat/chatEventBus.ts:48-120`).
- `SSEBuffer` is a fixed-size ring buffer for event-id deduplication (`frontend/src/data/Chat/utils/SSEBuffer.ts:1-94`).
- `handleStreamingEvents` seeds `SSEBuffer` from persisted raw event ids, pushes duplicate events to Faro, batches `conversation-update` events per animation frame, and flushes on `done` (`frontend/src/data/Chat/queries.ts:122-189`, `frontend/src/data/Chat/queries.ts:191-242`).

### Thread guard and subscriptions

- `isEventForActiveThread` permits legacy unstamped events, drops stamped events before the active thread resolves, and otherwise requires `event.thread_id === activeThreadRef.current` (`frontend/src/data/Chat/chatEventGuard.ts:1-18`).
- `useChatWithAbort` wires query-client cache subscriptions, abort controllers, streaming context (last timestamp, existing event ids, thread id), and SSE restart on draft switch (`frontend/src/data/Chat/queries.ts:365-392`, `frontend/src/data/Chat/queries.ts:394-483`, `frontend/src/data/Chat/queries.ts:485-519`).
- `setupChatEventSubscriptions` registers Thread, AppCode, and Application handlers, plus app name/state cache updates (`frontend/src/data/Chat/subscriptions.ts:10-21`, `frontend/src/data/Chat/subscriptions.ts:22-84`).
- Thread handlers update conversation messages, iteration phase/state, generated images/logo/content/design, suggestions/options, checkpoint invalidation, and app-state caches (`frontend/src/data/Thread/chatHandlers.ts:87-199`, `frontend/src/data/Thread/chatHandlers.ts:313-434`, `frontend/src/data/Thread/chatHandlers.ts:493-738`). Handler registration is guarded by `thread_id` (`frontend/src/data/Thread/chatHandlers.ts:740-868`).
- Application handlers invalidate app/page-path queries after building/writing/discoverability/redesign work and checkpoint restores, and invalidate page paths on preview navigation (`frontend/src/data/Application/chatHandlers.ts:7-27`, `frontend/src/data/Application/chatHandlers.ts:29-60`, `frontend/src/data/Application/chatHandlers.ts:62-88`).

### SSE maintainability risks

There is important drift among SSE types, parser cases, event-type registration, and handlers:

- `ChatStreamEvent` includes `agent_tiles`, `checkpoint_restored`, `user_action_complete`, and `generated_app_error` (`frontend/src/data/Chat/types.ts:88-98`, `frontend/src/data/Chat/types.ts:128-156`, `frontend/src/data/Chat/types.ts:360-373`), and handlers subscribe to several of these (`frontend/src/data/Thread/chatHandlers.ts:779-800`, `frontend/src/data/Thread/chatHandlers.ts:842-846`).
- `SSE_EVENT_TYPES` does **not** list `checkpoint_restored`, `user_action_complete`, `agent_tiles`, or `generated_app_error`, and `parseSSEEvent` has no cases for them (`frontend/src/data/Chat/api.ts:369-397`). Those events will not reach the bus if sent only by EventSource.
- `ChatStreamDiscoverabilityReport` models optional `prev_google_score`, `discoverability_score`, and `prev_discoverability_score` (`frontend/src/data/Chat/types.ts:288-300`), and the thread handler reads these (`frontend/src/data/Thread/chatHandlers.ts:625-636`), but the parser only returns kite/google scores, issues, summary, id, timestamp, and thread id (`frontend/src/data/Chat/api.ts:306-319`).

For future event work, keep the event union, parser, `SSE_EVENT_TYPES`, tests/fixtures, and registered handlers in lockstep.

## `pages/AppDetails` architecture

`AppDetails` is the central product workspace.

### Provider composition

- `AppDetails` reads `appId`, clears design state on unmount, handles Slack OAuth URL results, fetches the app and latest thread, and runs draft-id synchronization (`frontend/src/pages/AppDetails/AppDetails.tsx:26-89`).
- It renders an error state if either app or latest thread fails (`frontend/src/pages/AppDetails/AppDetails.tsx:90-102`).
- The normal tree composes `SendMessageContext`, `PreviewStateContext`, `AgentStatusContext`, conversation/onboarding/publish contexts, `ChatContext`, `AppLayout`, nested route `Outlet`, workflow notification, and unsaved-changes dialog (`frontend/src/pages/AppDetails/AppDetails.tsx:104-135`).

### Context responsibilities

- `ChatContext` wraps `useChatWithAbort` and retries streaming with exponential backoff from 1s up to 30s, capped at 10 retries (`frontend/src/pages/AppDetails/contexts/ChatContext/context.tsx:5-13`, `frontend/src/pages/AppDetails/contexts/ChatContext/context.tsx:31-78`).
- `SendMessageContext` centralizes message send and stop-workflow behavior, including queue invalidation, analytics, browser suspension retry, 429 queue-full toast, and generic send failure toast (`frontend/src/pages/AppDetails/contexts/SendMessageContext/context.tsx:40-68`, `frontend/src/pages/AppDetails/contexts/SendMessageContext/context.tsx:70-138`).
- `AgentStatusContext` derives workflow/orchestrator status from persisted thread events and live notification/error events; it tracks timeouts, suppresses stale “thinking” states, and exposes workflow status to UI (`frontend/src/pages/AppDetails/contexts/AgentStatusContext/context.tsx:43-112`, `frontend/src/pages/AppDetails/contexts/AgentStatusContext/context.tsx:113-231`, `frontend/src/pages/AppDetails/contexts/AgentStatusContext/context.tsx:233-299`).
- `PreviewStateContext` owns preview/finalization/checkpoint state, app/draft sandbox selection, chat-error toasts, finalizing-design transitions, sandbox invalidation, and derived preview state (`frontend/src/pages/AppDetails/contexts/PreviewStateContext/context.tsx:30-80`, `frontend/src/pages/AppDetails/contexts/PreviewStateContext/context.tsx:97-176`, `frontend/src/pages/AppDetails/contexts/PreviewStateContext/context.tsx:205-260`, `frontend/src/pages/AppDetails/contexts/PreviewStateContext/context.tsx:261-383`).

### Layout and state stores

- `AppLayoutWithNavigation` adapts between desktop/narrow/mobile, hides/collapses sidebars for pre-edit/maximized states, and mounts mobile chat preview only when appropriate (`frontend/src/pages/AppDetails/components/AppWithNavigationLayout.tsx:17-75`).
- The sidebar is feature-aware, state-aware, and shows tabs for website/code/content/analytics/drafts/settings depending on app state, feature flags, and `viewer_role` (`frontend/src/pages/AppDetails/components/Navigation/SideBar/SideBar.tsx:81-170`).
- Mobile bottom navigation uses links/dropdown semantics and ARIA state for preview-menu behavior (`frontend/src/pages/AppDetails/components/Navigation/AppBottomNavigation.tsx:48-86`, `frontend/src/pages/AppDetails/components/Navigation/AppBottomNavigation.tsx:136-161`).
- Page-local Zustand stores cover preview iframe refs/current path/maximized state, grab interaction mode/chips, pending edits, unread chat, design generation/selection UI, and credit recharge (`frontend/src/pages/AppDetails/stores/previewStore.ts:1-90`, `frontend/src/pages/AppDetails/stores/grabStore.ts:1-65`, `frontend/src/pages/AppDetails/stores/pendingEditsStore.ts:1-101`, `frontend/src/pages/AppDetails/stores/unreadChatStore.ts:1-11`, `frontend/src/pages/AppDetails/stores/designStore.ts:1-86`).

## Components and design system

### Reusable component patterns

- `Button` uses `tailwind-variants`, Radix `Slot` for `asChild`, semantic token classes, pending/loading state, disabled/aria-disabled handling, `aria-pressed`, and spinner `role="status"`/`aria-label="Loading"` (`frontend/src/components/ui/button/button.tsx:11-45`, `frontend/src/components/ui/button/button.tsx:47-124`).
- `ActionPopover` renders a Radix Popover on desktop and a bottom Sheet on mobile, matching component-guide interaction rules (`frontend/src/components/ui/action-popover/action-popover.tsx:30-90`).
- `ConfirmDialog` renders AlertDialog on desktop and bottom Sheet on mobile, supports destructive/default variants and pending disabled state (`frontend/src/components/ui/confirm-dialog/confirm-dialog.tsx:25-151`).
- `CrossLinkDialog` renders Dialog on desktop and fullscreen right-side Sheet on mobile with a back button and `sr-only` label (`frontend/src/components/ui/cross-link-dialog/cross-link-dialog.tsx:25-107`).
- `PageLayout` provides a sticky header, optional title/actions, TanStack Router links wrapped in Tabs, and constrained content widths (`frontend/src/components/PageLayout.tsx:8-128`).
- `PageContainer` provides responsive global navigation with mobile menu button ARIA label and Sheet drawer (`frontend/src/components/PageContainer.tsx:18-80`).
- `Box` and `Spinner` provide common shell/loading primitives; Spinner uses `role="status"` and `aria-label="Loading"` (`frontend/src/components/Box.tsx:5-23`, `frontend/src/components/ui/spinner/spinner.tsx:5-16`).

### Tokens, themes, and accessibility

- `styles.css` imports Tailwind/theme/utilities, defines the `dark` custom variant based on `[data-theme='dark']`, global color-scheme, safe-area padding, and font smoothing (`frontend/src/styles.css:1-21`, `frontend/src/styles.css:36-57`).
- `theme.css` defines semantic tokens in Tailwind `@theme`; comments explicitly require semantic tokens to be composed from primitives via `light-dark()` and not raw `oklch(...)` literals (`frontend/src/styles/theme.css:1-8`).
- Core semantic tokens include background, neutral backgrounds, foreground hierarchy, borders, focus shadows, and surface custom properties (`frontend/src/styles/theme.css:21-207`).
- Surface utilities provide `surface-0`, `surface-depth-1`, and `surface-elevation-1` (`frontend/src/styles/theme.css:209-228`).
- `shared.css` stores palette primitives, typography, radius, and bridge-consumable design-token primitives (`frontend/src/styles/shared.css:1-12`, `frontend/src/styles/shared.css:16-149`).
- `theme.test.ts` verifies core semantic tokens use `light-dark()`, avoids dark override blocks, and prevents raw `oklch(...)` literals inside the `@theme` block (`frontend/src/styles/theme.test.ts:11-50`).

Accessibility is present in component primitives (Radix-based dialogs/sheets/popovers, role/status labels, ARIA labels/states), but the repo relies on contributor discipline and semantic queries in tests rather than a dedicated automated a11y suite in the files reviewed.

## Iframe bridge capabilities

The preview/product workspace relies heavily on iframe capabilities injected into generated app sandboxes through `script_injector.js` readiness messages.

### Preview and sandbox iframe lifecycle

- `PreviewIframe` composes `IframeGestureWrapper`, `UrlChangeWrapper`, and `SandboxIframe`; it preserves scroll, tracks URL path, refreshes, navigates by path, and registers the iframe in `previewStore` (`frontend/src/lib/preview-iframe/PreviewIframe.tsx:59-79`, `frontend/src/lib/preview-iframe/PreviewIframe.tsx:97-166`, `frontend/src/lib/preview-iframe/PreviewIframe.tsx:168-247`).
- It handles sandbox origin rotation by imperatively applying a new origin to the live iframe while preserving path/search/hash (`frontend/src/lib/preview-iframe/PreviewIframe.tsx:108-139`, `frontend/src/lib/preview-iframe/PreviewIframe.tsx:168-198`).
- `SandboxIframe` polls readiness before rendering the iframe and shows spinner or timeout/retry UI (`frontend/src/lib/sandbox-iframe/SandboxIframe.tsx:31-100`).
- `useSandboxPolling` pings `/sandbox/ping?url=...`, triggers a final-attempt self-heal with optional `sandbox_id`, and grants a 30-second post-restart grace window (`frontend/src/lib/hooks/useSandboxPolling.ts:20-27`, `frontend/src/lib/hooks/useSandboxPolling.ts:44-138`).

### Scroll, URL, and overscroll bridges

- `IframeGestureWrapper` injects scroll bridge, scroll restore bridge, and mobile-only overscroll control on `script-injector` readiness; it filters postMessages by iframe `contentWindow` and exposes scroll-overflow/active callbacks (`frontend/src/lib/iframe-gesture-wrapper/index.tsx:33-120`, `frontend/src/lib/iframe-gesture-wrapper/index.tsx:122-186`).
- `UrlChangeWrapper` injects URL-change capability and exposes `url-change` events after iframe-source filtering (`frontend/src/lib/iframe-url-change-wrapper/index.tsx:16-105`).
- Capability modules stringify runtime functions into injectable IIFEs and expose capability objects (`frontend/src/lib/scroll-bridge/index.ts:20-37`, `frontend/src/lib/scroll-restore-bridge/index.ts:15-32`, `frontend/src/lib/overscroll-control-bridge/index.ts:12-29`, `frontend/src/lib/url-change-bridge/index.ts:15-32`).

### Grab/edit bridge and replay bridges

- `grab-bridge` defines outbound iframe message types for element selection, image edits, text edits, edit deletion, and element deletion (`frontend/src/lib/grab-bridge/index.ts:1-100`).
- `GrabBridgeWrapper` injects the grab capability, transfers font bytes to the iframe to avoid CORS, sends mobile/edit/loading commands, listens for all `v2-*` events, exposes imperative methods, and cleans up on unmount (`frontend/src/lib/grab-bridge/GrabBridgeWrapper.tsx:132-249`, `frontend/src/lib/grab-bridge/GrabBridgeWrapper.tsx:251-385`, `frontend/src/lib/grab-bridge/GrabBridgeWrapper.tsx:387-486`).
- `useGrabBridge` syncs Zustand store state to the iframe and maps iframe events to chips, pending edits, image edit dialog state, and analytics (`frontend/src/lib/grab-bridge/useGrabBridge.ts:41-114`, `frontend/src/lib/grab-bridge/useGrabBridge.ts:119-219`, `frontend/src/lib/grab-bridge/useGrabBridge.ts:225-260`).
- PostHog and Mixpanel replay bridge modules follow the same capability-object/stringified-runtime model (`frontend/src/lib/posthog-replay-bridge/index.ts:1-36`, `frontend/src/lib/mixpanel-replay-bridge/index.ts:1-36`).

Security/maintainability note: bridge wrappers validate that messages come from their nested iframe via `event.source`, but injection and commands use `postMessage(..., '*')` (`frontend/src/lib/iframe-gesture-wrapper/index.tsx:60-100`, `frontend/src/lib/iframe-url-change-wrapper/index.tsx:39-50`, `frontend/src/lib/grab-bridge/GrabBridgeWrapper.tsx:215-225`). If the iframe origin can be untrusted or attacker-controlled, future bridge work should consider explicit target-origin and origin allowlist checks.

## Testing and MSW setup

- Vitest config runs in jsdom, loads `src/test/setup.ts`, includes only `src/**/*.{test,spec}.*`, excludes E2E folders, and aliases `virtual:grab-bridge-runtime` to a test mock (`frontend/vitest.config.ts:6-32`).
- Test setup installs jest-dom, mocks IntersectionObserver/ResizeObserver/matchMedia, starts MSW before all tests with `onUnhandledRequest: 'warn'`, resets handlers after each test, and closes the server after all tests (`frontend/src/test/setup.ts:1-94`).
- `renderWithProviders` wraps React Testing Library render with a no-retry test QueryClient, ThemeProvider, and Toaster (`frontend/src/test/test-utils.tsx:1-60`).
- The MSW handler registry composes handlers from entity folders including Analytics, Application, Chat, Discoverability, FeatureFlags, Thread, and User (`frontend/src/test/mocks/handlers.ts:1-31`).
- Browser MSW uses the same handler list for E2E/mock dev (`frontend/src/test/mocks/browser.ts:1-11`).
- MSW utilities support common error/delay/network/error endpoint overrides and call trackers (`frontend/src/test/mocks/utils.ts:1-126`, `frontend/src/test/mocks/utils.ts:167-180`).
- `TESTING.md` recommends colocated tests, `renderWithProviders`, user-behavior assertions, semantic queries, async `waitFor`, and test utility imports (`frontend/TESTING.md:24-53`, `frontend/TESTING.md:99-144`).

Potential testing gap: `onUnhandledRequest: 'warn'` makes tests less brittle during development but can allow missing mocks/API calls to pass unnoticed (`frontend/src/test/setup.ts:78-83`). Critical flows may benefit from targeted tests with stricter handler expectations or call trackers.

## Maintainability and scalability assessment

### Strengths

- Clear architectural boundaries are documented and mostly followed: centralized routes, page-local state, entity data folders, global/page-specific component separation.
- TanStack Router search validation and route guards keep URL state typed and explicit (`frontend/src/routes.tsx:100-172`, `frontend/src/routes.tsx:230-398`).
- TanStack Query is used as the server-state/cache authority, with entity query-key factories and mutation cache updates for optimistic/no-flicker UX (`frontend/src/data/Application/queries.ts:48-57`, `frontend/src/data/Application/queries.ts:122-181`).
- Real-time SSE events are decoupled through an event bus and domain handlers instead of letting UI components mutate every cache directly (`frontend/src/data/Chat/subscriptions.ts:10-84`).
- `AppDetails` contexts split large workspace concerns into streaming, send/stop workflow, agent status, preview state, onboarding/banner/publish, and layout (`frontend/src/pages/AppDetails/AppDetails.tsx:111-134`).
- Tailwind semantic tokens and tests protect theme consistency and light/dark behavior (`frontend/src/styles/theme.css:1-8`, `frontend/src/styles/theme.test.ts:11-50`).
- Responsive UI patterns are componentized through ActionPopover/ConfirmDialog/CrossLinkDialog rather than repeated per feature (`frontend/src/components/ui/action-popover/action-popover.tsx:30-90`, `frontend/src/components/ui/confirm-dialog/confirm-dialog.tsx:76-151`, `frontend/src/components/ui/cross-link-dialog/cross-link-dialog.tsx:53-107`).

### Risks and watch points

1. **Growing central route file.** `routes.tsx` centralizes all route declarations and guards, which matches current docs, but it is already large and mixes auth, feature gates, redirects, search validation, and tree assembly. If it grows further, consider extracting route groups/guards while preserving central route-tree assembly.
2. **SSE contract drift.** Event types, parser, EventSource registration, and handlers are not fully synchronized. This is the highest-value correctness risk for future real-time features.
3. **Docs/code drift.** Existing `any`, enum, deprecated/hardcoded color tokens, and inconsistent query-key patterns show the repo has legacy exceptions. New code should follow the documented conventions rather than copying every local pattern blindly.
4. **Iframe trust boundaries.** Bridge wrappers filter by iframe source but use wildcard target origins. That may be acceptable for controlled generated sandboxes, but it should be revisited before exposing bridges to arbitrary origins.
5. **AppDetails coupling.** Contexts are well-separated by concern, but they still share implicit contracts through React Query caches, `activeThreadRef`, SSE events, and Zustand stores. Changes to draft/thread behavior should include integration-style tests around SSE filtering, preview state, and cache updates.
6. **MSW strictness.** Global unhandled requests warn instead of fail, which is useful for broad development but can hide missing mocks. Critical data modules should use explicit handler/call-tracker assertions.

## Suggested validation commands for future frontend changes

For architecture-only doc updates, no runtime validation is strictly required. For source changes in this app, use:

```bash
cd frontend && pnpm lint
cd frontend && pnpm typecheck
cd frontend && pnpm test:run
```

For route/auth/data-layer changes, targeted checks should include `src/routes.test.tsx` and relevant entity tests. For theme/token changes, run `src/styles/theme.test.ts`. For SSE/event changes, add targeted tests that verify the event union, parser, `SSE_EVENT_TYPES`, and domain handlers remain aligned.
