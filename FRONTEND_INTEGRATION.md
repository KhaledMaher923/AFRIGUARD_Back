# Nairobi Flood Guard — Frontend Integration Guide

**Audience:** Frontend / UI engineering teams integrating a web or mobile
frontend with the Nairobi Flood Guard platform.

**Document version:** 1.0 · **Backend API version:** 3.0 (see `/registry`)



## Table of Contents

1. [Project Overview](#1-project-overview)
2. [System Architecture](#2-system-architecture)
3. [Tech Stack](#3-tech-stack)
4. [Running the Platform](#4-running-the-platform)
5. [API Reference](#5-api-reference)
6. [Data Contracts & Schemas](#6-data-contracts--schemas)
7. [Alert Feeds (JSON / RSS / CAP)](#7-alert-feeds-json--rss--cap)
8. [GTFS-Realtime Feed](#8-gtfs-realtime-feed)
9. [Webhooks (Inbound SMS)](#9-webhooks-inbound-sms)
10. [Risk Model & Display Semantics](#10-risk-model--display-semantics)
11. [Design System & Theming](#11-design-system--theming)
12. [Environment Variables & Secrets](#12-environment-variables--secrets)
13. [Integration Checklist](#13-integration-checklist)
14. [Known Constraints & Gotchas](#14-known-constraints--gotchas)

---

## 1. Project Overview

Nairobi Flood Guard is a data-science platform that predicts **flood
susceptibility across Kenya's 1,450 administrative wards** and recommends
**safe matatu (minibus) routes** during flood events.

Two products exist today:

| Surface | Technology | Purpose |
| :--- | :--- | :--- |
| **Streamlit app** | Python / Streamlit | Interactive dashboard (maps, ward lookup, routing, alerts, AI assistant) |
| **REST API** | Python / FastAPI | Machine-consumable model serving, rerouting, and alert feeds |

The REST API is the **primary integration surface for a new frontend**. It is
fully decoupled from the UI and can be consumed by any HTTP client. This
document centres on it.

**Model fact sheet** (from `Models/model_registry.json`, the single source of truth):

- Model: calibrated **XGBoost** classifier, v3.0
- Granularity: ward-level (polygon) predictions, nationwide
- Probability semantics: **isotonic-calibrated** — `flood_prob` is readable as a
  real frequency (e.g. `0.45` = 45%)
- Operating threshold: **~0.30** (highest precision at recall ≥ 80%,
  county-held-out spatial CV)
- Honest spatial metrics: ROC AUC **0.889**, PR AUC **0.690**, recall **0.80**,
  precision **0.57**, Brier **0.103**
- Predicts **susceptibility**, not flood timing or depth

---

## 2. System Architecture

```
                         ┌──────────────────────────────────────────┐
                         │             Frontend (yours)             │
                         └───────▲──────────────────────────▲───────┘
                                 │ HTTPS/JSON                │ GTFS-RT protobuf
                                 │                           │
   ┌─────────────────────────────┴──────────┐   ┌────────────┴──────────────┐
   │  FastAPI  api/main:app  (port 8000)    │   │  Public feeds             │
   │  /health /registry /wards /reroutes    │   │  /alerts/feed (JSON)      │
   │  /alerts /reports /subscribers         │   │  /alerts/feed/rss (RSS2)  │
   │                                        │   │  /alerts/cap/feed (CAP1.2)│
   └───────────────▲──────────────▲─────────┘   └───────────────────────────┘
                   │              │
                   │ reads        │ reads
        ┌──────────┴───────┐  ┌───┴───────────────────────────┐
        │ Models/registry  │  │ cache/precomputed_reroutes.json│  <- scheduled refresh
        │ floods.gpkg      │  │ cache/flood_reports.db (SQLite)│  <- subscribers, alerts,
        └──────────────────┘  └───────────────────────────────┘     reports
```

Key design principles:

- **API and UI share one contract.** Both read `Models/model_registry.json`
  (model path, feature list, threshold) and the same SQLite store
  (`Utils/alert_store.py`) so serving can never drift from training.
- **Rerouting is precomputed.** A scheduled job
  (`scripts/refresh_cache.py`) writes `cache/precomputed_reroutes.json`; the
  API serves it without loading the ~87k-node road graph. If the cache is
  stale or threshold mismatched, the API computes **on demand** — the first
  call can take ~30 s.
- **SMS early warning is autonomous.** A scheduled refresh diffs ward
  probabilities against the last snapshot and alerts subscribers who **newly
  crossed** the threshold (never repeatedly while risk stays high).

---

## 3. Tech Stack

Backend runtime (`requirements.txt`, pinned):

| Layer | Library |
| :--- | :--- |
| API framework | FastAPI `0.141` + Uvicorn `0.52` |
| ML / data | scikit-learn `1.9`, XGBoost `3.4`, numpy, pandas, geopandas |
| Geospatial / graph | shapely, networkx, osmnx `2.1`, folium |
| App UI (existing) | Streamlit `1.61`, streamlit-folium, plotly |
| Alerts | africastalking `2.0` (SMS/WhatsApp) |
| AI assistant | groq `1.6` (LLM `llama-3.3-70b-versatile`) |
| Transit feed | gtfs-realtime-bindings `2.2` (protobuf) |

**No CORS middleware is currently configured** on the API. If your frontend
runs in a browser (fetch/XHR cross-origin), add `CORSMiddleware` in
`api/main.py` or configure a reverse proxy. See
[Integration Checklist](#13-integration-checklist).

---

## 4. Running the Platform

Local / single-command demo (POSIX shell):

```bash
make demo            # asset preflight -> cache warm-up -> API (:8000) + app (:8501)
make app             # Streamlit UI only  -> http://localhost:8501
make api             # FastAPI only       -> http://localhost:8000  (docs at /docs)
make refresh-cache   # refresh live rainfall, rescore wards, rebuild reroutes, run alert loop
```

Dockerised:

```bash
docker compose up    # api -> :8000, app -> :8501
```

Production service:

```bash
uvicorn api.main:app --host 0.0.0.0 --port $PORT
```

**Interactive API docs:** `GET http://<host>:8000/docs` (Swagger UI) and
`/openapi.json` for a machine-readable OpenAPI spec you can feed directly into
your API client generators.

Scheduled jobs (run on cron / CI / PaaS scheduler):

```bash
python -m scripts.refresh_cache [--threshold 0.30] [--skip-rainfall]
                                [--no-alerts] [--alert-on-baseline]
```

---

## 5. API Reference

Base URL: `http://<host>:8000` (dev) or your deployed API URL.

### 5.1 System

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/health` | Liveness + model version |
| GET | `/registry` | Full model contract: feature list, threshold, CV scheme, metrics, library versions |
| GET | `/docs` | Swagger UI |

`GET /registry` response (abridged — see `Models/model_registry.json`):

```json
{
  "version": "3.0",
  "model_path": "Models/flood_model.joblib",
  "feature_cols": ["elevation_mean_m", "elevation_min_m", "...", "pop_density"],
  "n_features": 14,
  "threshold": 0.2967171718676885,
  "threshold_policy": "max precision subject to recall >= 0.8 on calibrated spatial out-of-fold predictions",
  "precision_at_threshold": 0.5652,
  "recall_at_threshold": 0.8046,
  "calibration": "isotonic (CalibratedClassifierCV, county-grouped folds)",
  "cv": { "scheme": "GroupKFold(5) grouped by county", "n_groups": 47 },
  "metrics_spatial_oof": { "roc_auc": 0.8892, "pr_auc": 0.6904, "brier": 0.1028, "recall": 0.8046, "precision": 0.5652, "f1": 0.6640 },
  "metrics_random_split": { "roc_auc": 0.9235, "note": "..." },
  "labels": { "events": ["FL20240426KEN (UNOSAT, April 2024)"], "note": "..." },
  "library_versions": { "python": "3.12.3", "xgboost": "3.4.0", "scikit-learn": "1.9.0", "numpy": "2.4.4" }
}
```

### 5.2 Ward Risk

**`GET /wards/risk`** — scored wards, sorted by risk descending.

Query params:

| Param | Type | Default | Notes |
| :--- | :--- | :--- | :--- |
| `county` | string | *all* | Case-insensitive; `404` if unknown |
| `threshold` | float 0–1 | registry threshold | Overrides high-risk boundary |

Response:

```json
{
  "threshold": 0.2967,
  "rainfall": "historical (CHIRPS Feb-Apr 2024)",
  "n_wards": 1450,
  "n_high_risk": 123,
  "wards": [
    { "ward": "Soweto", "subcounty": "Embakasi East", "county": "Nairobi", "flood_prob": 0.8812, "high_risk": true },
    { "ward": "Ruai", "subcounty": "Kasarani", "county": "Nairobi", "flood_prob": 0.6700, "high_risk": true }
  ]
}
```

> Note: the API always scores with **historical (April 2024) rainfall** features.
> Live/forecast rainfall is a Streamlit-app-only feature today. If your
> frontend needs live rainfall you will want to call the app's scoring path or
> add a live-scoring endpoint (feature request).

**`GET /wards/{ward}/risk`** — one ward's probability plus raw features.

Response:

```json
{
  "ward": "Ruai",
  "subcounty": "Kasarani",
  "county": "Nairobi",
  "flood_prob": 0.6700,
  "high_risk": true,
  "features": {
    "elevation_mean_m": 1548.2,
    "elevation_min_m": 1496.1,
    "elevation_max_m": 1612.7,
    "elev_range_m": 116.6,
    "terrain_roughness": 0.0753,
    "slope_mean_deg": 1.92,
    "twi_proxy": 13.71,
    "rain_cumulative_mm": 610.4,
    "rain_max_daily_mm": 82.1,
    "rain_preflood_7d_mm": 55.3,
    "rain_recency_ratio": 0.0906,
    "rain_intensity_ratio": 1.4846,
    "ward_area_km2": 9.12,
    "pop_density": 143.2
  }
}
```

### 5.3 Rerouting (Matatu Route Optimization)

**`GET /reroutes`** — the Pareto rerouting option set for affected routes.

Query params:

| Param | Type | Default | Notes |
| :--- | :--- | :--- | :--- |
| `preference` | enum | `balanced` | One of `fastest`, `balanced`, `safest` |
| `threshold` | float 0–1 | registry threshold | Must match cache or a recompute is triggered |

Detour semantics (the alpha in `cost = travel_time × (1 + α × flood_prob)`):

| Option | α | Meaning |
| :--- | :--- | :--- |
| `fastest` | 5 | Mild penalty — short detours, may retain some flood exposure |
| `balanced` | 50 | Most of the risk reduction at a fraction of the detour |
| `safest` | 1e6 | Practical infinity — flood-touched roads are impassable; only returned if a fully flood-free path exists |

Response:

```json
{
  "threshold": 0.2967,
  "preference": "balanced",
  "generated_at": "2026-08-15T06:00:00+00:00",
  "served_from": "precomputed",
  "meta": {
    "alphas": { "fastest": 5.0, "balanced": 50.0, "safest": 1000000.0 },
    "threshold": 0.2967,
    "total_affected_routes": 34,
    "rerouted_routes": 30,
    "affected_stops": 118,
    "service_radius_m": 300
  },
  "routes": [
    {
      "route_id": "50703033J01",
      "origin": "Githunguri",
      "destination": "Cabanas",
      "option": "balanced",
      "alpha": 50.0,
      "original_flood_prob": 0.378,
      "original_max_flood_prob": 0.881,
      "original_risk_time_frac": 0.42,
      "alternative_flood_prob": 0.035,
      "alternative_max_flood_prob": 0.201,
      "alternative_risk_time_frac": 0.0,
      "risk_reduction": 0.343,
      "original_time_s": 881.8,
      "alternative_time_s": 1704.8,
      "extra_time_min": 13.7,
      "stops_total": 18,
      "stops_served": 16,
      "stops_dropped": 2,
      "same_as_original": false
    }
  ],
  "all_options": [ ... ]
}
```

Field notes:

- `risk_reduction` and `flood_prob` values are **exposure-weighted**
  (travel-time-weighted means), not simple averages.
- `stops_served` = stops within **300 m** of the alternative path.
- `routes` = one row per route for your requested `preference` (with fallback to
  the closest deduplicated option); `all_options` = every (route, option) pair.

### 5.4 GTFS-Realtime Feed

**`GET /reroutes/gtfs-rt`** — same option set as a **GTFS-Realtime v2.0
protobuf feed**, immediately consumable by transit apps (Google Maps, Transit
App). Content-Type: `application/x-protobuf`. One `ADDED` TripUpdate per trip
of every affected route; stops inside high-risk wards are flagged `SKIPPED`.

> Parsing the protobuf requires `gtfs-realtime-bindings` (or any GTFS-RT
> parser). The feed is not plain JSON.

### 5.5 Alerts & Subscribers

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| GET | `/alerts?limit=200` | Alert audit log; **phone numbers masked** (`+254****5678`) |
| GET | `/alerts/feed?limit=50` | Public JSON alert feed (no auth) |
| GET | `/alerts/feed/rss` | RSS 2.0 wrapper |
| GET | `/alerts/cap/feed` | CAP 1.2 XML feed |
| POST | `/subscribers` | Opt a phone into SMS/WhatsApp alerts for a ward or county |
| DELETE | `/subscribers` | Deactivate a subscription |
| GET | `/reports?limit=100` | Field flood reports (candidate retraining labels) |

**`POST /subscribers`** request body:

```json
{
  "phone": "+254712345678",
  "ward_or_county": "Ruai",
  "language": "en"
}
```

Validation: `phone` must match E.164 (`+[1-9]\d{6,14}`); `language` is `en` or
`sw` (Kiswahili). Re-subscribing the same `(phone, ward_or_county)` pair is
idempotent and reactivates the row.

**`DELETE /subscribers?phone=+254712345678&ward_or_county=Ruai`** — 404 if no
such subscription exists.

### 5.6 Flood Reports (Ground Truth)

**`POST /reports`** request body:

```json
{
  "text": "Road flooded near Soweto bus stop",
  "phone": "+254712345678",
  "ward": "Soweto",
  "county": "Nairobi",
  "lat": -1.2833,
  "lon": 36.8167
}
```

`text` is required (1–2000 chars); everything else optional. Returns
`201 {"id": 5, "status": "stored"}`. Reports accumulate as **candidate labels
for model retraining** — the scarcest asset in the system, so treat them as
valuable.

---

## 6. Data Contracts & Schemas

### 6.1 Ward record (GeoJSON / rows)

The base spatial dataset is `Data/floods.gpkg` (GeoPackage). Per-ward fields
available via the API and app:

| Field | Type | Meaning |
| :--- | :--- | :--- |
| `ward` | string | Administrative ward name |
| `subcounty` | string | Sub-county |
| `county` | string | County (47 counties) |
| `pop2009` | float | Ward population, 2009 census |
| `elevation_mean_m` / `elevation_min_m` / `elevation_max_m` | float | SRTM 90 m elevation (m) |
| `slope_mean_deg` | float | Mean slope (°) |
| `rain_cumulative_mm` | float | Cumulative rainfall, last 90 days |
| `rain_max_daily_mm` | float | Max single-day rainfall |
| `rain_preflood_7d_mm` | float | Rainfall in last 7 days |
| `geometry` | Polygon | Ward boundary, EPSG:4326 |

### 6.2 Rerouting option row

Exact column set (from `Utils/live_routing.py::OPTION_ROW_COLS`):

`route_id, origin, destination, option, alpha, original_flood_prob,
original_max_flood_prob, original_risk_time_frac, alternative_flood_prob,
alternative_max_flood_prob, alternative_risk_time_frac, risk_reduction,
original_time_s, alternative_time_s, extra_time_min, stops_total,
stops_served, stops_dropped, same_as_original`

### 6.3 Alert feed item (JSON)

```json
{
  "id": "2b1f9a18-...",
  "timestamp": "2026-08-15T06:00:12.123456+00:00",
  "ward": "Ruai",
  "severity": "Extreme",
  "channel": "sms",
  "status": "sent",
  "message": "FLOOD ALERT: ..."
}
```

Severity values are CAP-aligned: `Minor`, `Moderate`, `Severe`, `Extreme`.

### 6.4 Subscriber / Report rows (SQLite store)

The persistence layer is a single SQLite DB (`cache/flood_reports.db` by
default; override with `REPORTS_DB_PATH`). Three flat tables:

- `flood_reports(id, created_at, source, phone, ward, county, lat, lon, text)`
- `subscribers(id, phone, ward_or_county, language, created_at, active)` — unique on `(phone, ward_or_county)`
- `alerts_sent(id, timestamp, ward, phone, message, status, channel, severity, alert_id)`

---

## 7. Alert Feeds (JSON / RSS / CAP)

Three machine-readable feed formats are exposed **without authentication** so
partners (Kenya Red Cross, county disaster desks, newsrooms) can pick them up.

**JSON feed** — `GET /alerts/feed`:

```json
{
  "title": "Nairobi Flood Guard Live Alerts",
  "sender": "Nairobi Flood Guard (complements KMD & Kenya Red Cross)",
  "updated": "2026-08-15T06:00:12+00:00",
  "alerts": [ { "id": "...", "timestamp": "...", "ward": "...", "severity": "...", "channel": "sms", "status": "sent", "message": "..." } ]
}
```

**RSS 2.0** — `GET /alerts/feed/rss` (`application/rss+xml`).

**CAP 1.2** — `GET /alerts/cap/feed` (`application/xml`). Each alert is a valid
OASIS CAP 1.2 `<alert>` document. This is the Emergency Early Warning for All
(EW4All) alignment; it **complements** official Kenya Meteorological Department
(KMD) advisories and does not replace them.

> Recommended polling cadence: 5–15 minutes. `updated` is the newest alert
> timestamp; do a conditional refetch when it changes.

---

## 8. GTFS-Realtime Feed

`GET /reroutes/gtfs-rt?threshold=<0-1>` returns `application/x-protobuf`.

- Protocol: GTFS-Realtime **v2.0**
- One `TripUpdate` (entity) per trip of each affected route
- Stops inside high-risk wards are flagged as `SKIPPED`
- Consumable by Google Maps / Transit App / any GTFS-RT consumer

If your frontend targets commuters or operators, this is the feed to render as
"stop skipped / detour active" indicators on a transit map. Use a GTFS-RT
parser (e.g. `gtfs-realtime-bindings` in JS/Python).

---

## 9. Webhooks (Inbound SMS)

`POST /reports/sms` — Africa's Talking inbound-SMS webhook. Africa's Talking
POSTs `application/x-www-form-urlencoded` fields:

| Field | Meaning |
| :--- | :--- |
| `text` | Message body (required) |
| `from` | Sender MSISDN (mapped to `phone`) |

Response: `201 {"id": <report_id>, "status": "stored"}`. This feeds the
ground-truth loop — citizens' SMS reports become candidate retraining labels.

---

## 10. Risk Model & Display Semantics

### 10.1 Risk tiers (must match)

Derived from the calibrated `flood_prob` and the registry threshold:

| Tier | Range | CAP severity | Display color |
| :--- | :--- | :--- | :--- |
| Critical | `flood_prob ≥ 0.70` | Extreme | `#8B2E2E` (dark red) |
| High | `0.45 ≤ flood_prob < 0.70` | Severe | `#C4622D` (burnt orange) |
| Moderate | `threshold ≤ flood_prob < 0.45` | Moderate | `#D4A24C` (gold) |
| Low | `flood_prob < threshold` (~0.30) | Minor | `#3FA66B` (green) |

Source of truth: `app_lib/theme.py::risk_label` and `Utils/alerts.py::risk_tier`.

### 10.2 Live-vs-historical delta colors

When comparing live rainfall predictions to historical:

| Δ (`live − historical`) | Color |
| :--- | :--- |
| `≥ +0.03` | `#C4622D` |
| `+0.01..+0.03` | `#D4A24C` |
| `≤ −0.03` | `#2E7D9E` |
| `−0.01..−0.03` | `#5FA8C4` |
| negligible | `#1F4A32` |

### 10.3 Response protocol (who acts at which tier)

From `RESPONSE_PROTOCOL.md`:

- **Moderate** (≥ threshold): informational — dashboard + public feeds; SMS only
  for opted-in subscribers on a **new** threshold crossing.
- **High** (≥ 0.45): subscribers alerted (SMS + optional WhatsApp); reroute
  options published.
- **Critical** (≥ 0.70): escalation alert; county disaster desk notified
  (manual step).
- **Extreme / observed**: field reports + KMD advisory fuse in; manual
  broadcast available.

Alerting is **idempotent**: only new crossings fire; a ward that stays above
threshold alerts once. Failed sends are queued and retried on the next refresh.

---

## 11. Design System & Theming

If your frontend mirrors the existing Streamlit app, reuse this design
language (defined in `app_lib/theme.py`).

### Colors

| Token | Value | Use |
| :--- | :--- | :--- |
| `--ground` | `#07110D` | Page background |
| `--panel` | `#0E2318` | Card / panel background |
| `--panel-raised` | `#12301F` | Hover / raised panel |
| `--line` | `#1F4A32` | Borders |
| `--line-soft` | `#17321F` | Subtle borders |
| `--text` | `#E8DFC8` | Primary text |
| `--text-dim` | `#8FA894` | Secondary text |
| `--text-faint` | `#4E6357` | Captions / footnotes |
| `--accent` | `#D4A24C` | Accent / CTA / active states |

Risk colors are in [§10.1](#101-risk-tiers-must-match).

### Typography

- **Headings / numbers:** Fraunces (serif) — `letter-spacing: -0.01em`, weight 600
- **Body / labels / UI:** Space Mono (monospace) — uppercase labels, small sizes,
  wide letter-spacing (0.1–0.22 em) for eyebrow/section labels
- Google Fonts import: `Fraunces` + `Space Mono`

### Layout patterns used in the current UI

- **Header banner:** contour-line texture, eyebrow line + serif title + subtitle
- **Metric cards:** panel background, left accent border, uppercase label,
  serif large value, unit in mono
- **Section headers:** serif, bottom border, optional right-aligned context
- **Badges:** pill with dot, colored per risk tier
- **Map frame:** dark basemap (CartoDB dark_matter) with a thin themed border

### Component inventory (Streamlit pages to replicate)

| Page | Contents |
| :--- | :--- |
| **Dashboard** | 4 headline KPIs (people at risk, affected routes, avg risk reduction, stops served), KMD advisory expander, county choropleth, flood-probability histogram with threshold line, top-10 highest-risk wards table |
| **Ward Lookup** | Ward selector, risk badge + probability, feature cards, ward-vs-Kenya radar chart, ward map, SHAP/importance explanation bars |
| **Route Optimization** | Preference selector (fastest/balanced/safest), summary metrics, sortable rerouting table, CSV + GTFS-RT downloads, risk-vs-time tradeoff scatter, route explorer map with original/alternative paths, optional stop-preserving detour |
| **Live Alerts** | Public alert feed + feed endpoint links + warning performance stats (POD/FAR) |
| **Alert History** | Audit trail table (masked phones), subscriber count, verification stats, field reports table |
| **Model Card** | Registry-backed validation metrics, threshold policy, feature list, model comparison, stated limitations, March 2026 out-of-time sanity check |
| **AI Assistant** | Chat UI (Mlinzi), LLM-backed answers grounded in live ward/route data |

---

## 12. Environment Variables & Secrets

All secrets are **optional** — every feature degrades gracefully without them.

| Variable | Used by | Without it |
| :--- | :--- | :--- |
| `GROQ_API_KEY` | AI assistant | Assistant shows "unavailable" |
| `AT_API_KEY` / `AT_USERNAME` | SMS/WhatsApp (Africa's Talking) | Alerts logged as `no_credentials` |
| `VISUALCROSSING_API_KEY` | Rainfall fallback provider | Open-Meteo used alone |
| `REPORTS_DB_PATH` | SQLite path (default `cache/flood_reports.db`) | In-memory/ephemeral store — point at persistent storage in production |

Streamlit app secrets live in `.streamlit/secrets.toml` (local) or the
deployment's secret store. `docker compose up` passes the above through
environment variables.

---

## 13. Integration Checklist

Before shipping, confirm:

- [ ] **CORS.** If the frontend is browser-based and hosted elsewhere, add
      `CORSMiddleware` (allow origins, methods, headers) to `api/main.py`, or
      proxy the API through the same origin.
- [ ] **OpenAPI client.** Pull `GET /openapi.json` and generate typed client
      stubs (OpenAPI Generator, openapi-typescript, etc.) to keep payload types
      in sync.
- [ ] **Health gate.** Ping `GET /health` at startup; surface model version.
- [ ] **Threshold handling.** Read `GET /registry` and default UI threshold /
      risk bands from it rather than hardcoding.
- [ ] **Polling strategy.** Poll `GET /alerts/feed` (5–15 min) and react to the
      `updated` field; consider Server-Sent Events or websockets if you build
      real-time push (the API is pull-only today).
- [ ] **Rerouting freshness.** `GET /reroutes` may take ~30 s on a stale
      cache. Set a generous fetch timeout and show a "computing" state.
- [ ] **Phone privacy.** Render alert/report phone numbers through the
      `mask_phone` pattern (`+254****5678`). Never log full numbers client-side.
- [ ] **Language.** Alert content is authored in English and Kiswahili; choose a
      locale selector if you render messages.
- [ ] **Disclaimers.** Label the service as a **complement** to official KMD /
      Kenya Red Cross channels; ward-level granularity only, not doorstep
      forecasts.

---

## 14. Known Constraints & Gotchas

1. **Historical rainfall in the API.** `/wards/*` always scores with CHIRPS
   Feb–Apr 2024 rainfall. Live/24 h/48 h rainfall scoring currently exists only
   in the Streamlit app (`Utils/rainfall_fetcher.py`). Plan for it by
   consuming the API's static scores or requesting a live endpoint.
2. **Rerouting scope is Nairobi-only.** Ward risk is nationwide, but route
   optimization and alert feeds operate on the Nairobi GTFS feed (2019 Digital
   Matatus) — 136 routes, 4,284 stops.
3. **First `/reroutes` call is slow.** It loads an ~87k-node road graph if the
   precomputed cache is stale. `served_from: "precomputed" | "on_demand"` tells
   you which path served you.
4. **Threshold is a number, not a policy string.** Use
   `registry["threshold"]` (≈0.297) as the default; the API accepts an
   override per request. Lower it during extreme events to increase
   sensitivity.
5. **Exposure-weighted risk.** `flood_prob` on routes is travel-time-weighted;
   don't compare it directly to ward-level `flood_prob`.
6. **GTFS-RT is protobuf**, not JSON — use a GTFS-RT parser.
7. **Single-event labels.** The model was trained on one flood event
   (April 2024). The March 2026 out-of-time check in the Model Card is an
   honest sanity check, not a second validation metric — terrain-only
   susceptibility without live rainfall cannot reproduce flash-flood dynamics.
8. **Ephemeral storage.** On PaaS with ephemeral filesystems, set
   `REPORTS_DB_PATH` to a mounted persistent disk; otherwise subscribers and
   the alert audit trail reset on restart.

---

*Generated for the frontend engineering team by the Nairobi Flood Guard backend
maintainers. For questions, route through the project repo — the source of
truth for every endpoint, schema, and number referenced here.*
