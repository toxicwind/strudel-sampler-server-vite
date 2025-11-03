# Strudel Sampler Microservice

[![Node.js](https://img.shields.io/badge/Node.js-20+-339933?logo=node.js&logoColor=white)](https://nodejs.org/)
[![TypeScript](https://img.shields.io/badge/TypeScript-Strict-3178C6?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)
[![Tests](https://img.shields.io/badge/Tests-Passing-45ba68?logo=github)](../../actions)

Production-ready sampler service that scans a local library, exposes Strudel-compatible JSON/streaming endpoints, and provides a Vite middleware plugin for live-coding workflows.

> ℹ️ This repository is consumed by [`strudel-dev-vite`](https://github.com/toxicwind/strudel-dev-vite) via git submodule (`apps/sampler`). You can develop here standalone or from the parent workspace.

## Quick start

```bash
git clone git@github.com:toxicwind/strudel-sampler-server-vite.git
cd strudel-sampler-server-vite
npm install
cp .env.example .env
npm run dev             # middleware mode at http://localhost:5173/strudel-samples
# or
npm run sampler         # tsx entrypoint at http://localhost:5432
```

When working inside the parent workspace:

```bash
cd strudel-dev-vite
npm run sampler         # proxies to this package via workspace script
```

## Environment

Copy `.env.example` to `.env` and override as needed:

| Variable | Default | Purpose |
| --- | --- | --- |
| `STRUDEL_SAMPLES` | `./samples` | Root directory to scan (absolute or relative). |
| `PORT` | `5432` | HTTP port for the standalone server. |
| `CACHE_TTL` | `3600000` | Metadata cache duration in ms. |
| `CACHE_MAX_SIZE` | `500` | Max metadata entries before eviction. |
| `HOT_RELOAD` | `true` | Enables file-watch invalidation in dev mode. |

For container/Portainer deployments, see `docker-compose.yml` and adjust the same variables.

## Scripts

| Command | Description |
| --- | --- |
| `npm run dev` | Vite middleware server with live reload dashboard (`/dashboard`). |
| `npm run sampler` | tsx-powered local server (development). |
| `npm run sampler:prod` | Runs the compiled JS from `dist/`. |
| `npm run build` | TypeScript build into `dist/`. |
| `npm run type-check` | Strict type checking. |
| `npm run lint` | ESLint checks. |

## API surface

- `GET /` → JSON manifest compatible with `Strudel.samples()`.
- `GET /manifest` → manifest only (used by dashboard).
- `GET /metadata` → cached metadata (format, duration, size).
- `GET /stats` → service stats (counts, root path, cache state).
- `GET /files/:relativePath` → byte-range streaming route for audio files.
- Dashboard available at `/dashboard/` in dev builds for search/filter/playback.

## Development notes

- Audio formats allowed: `.mp3`, `.wav`, `.ogg`, `.flac`, `.m4a`, `.aiff` (modify `AUDIO_EXTENSIONS` in `vite-plugin-strudel-sampler.ts` to extend).
- Metadata is cached with TTL + max size; use `CACHE_TTL=0` to disable caching during heavy debugging.
- File watchers run when `HOT_RELOAD=true`; they invalidate caches and notify the Vite dev server when used as middleware.

## Integration checklist

1. Ensure your samples live under the folder referenced by `STRUDEL_SAMPLES` (bind-mount when using Docker).
2. Run `npm run sampler` and visit `http://localhost:5432/dashboard/` to verify indexing.
3. In Strudel, call `samples('http://localhost:5432/')` and trigger e.g. `s("kick_deep_95gm")`.
4. From the parent `strudel-dev-vite` repo, start the dev UI (`npm run dev`) and the sampler concurrently for a full-stack loop.

## License

Released under the MIT License. See `LICENSE` for details.
