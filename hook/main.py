"""
PharmaCX Source Tracker — FastAPI middleware
Intercepts AnythingLLM responses and appends structured source attribution:
  • Which LLM answered (local Ollama model name, or cloud provider)
  • Which local documents were cited (filename, workspace, chunk)
  • Which web sources were used (URL, title)
  • Data classification applied
Runs on port 5050, proxies to AnythingLLM on 3001.
"""

import os
import json
import time
import asyncio
import httpx
import re
from datetime import datetime, timezone
from typing import AsyncGenerator
from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("source_tracker")

ANYTHINGLLM_URL = os.getenv("ANYTHINGLLM_URL", "http://localhost:3001")
LITELLM_URL     = os.getenv("LITELLM_URL",     "http://localhost:8000")
OLLAMA_URL      = os.getenv("OLLAMA_URL",       "http://localhost:11434")

app = FastAPI(title="PharmaCX Source Tracker", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─────────────────────────────────────────────────────────────
# Source attribution builder
# ─────────────────────────────────────────────────────────────

def build_source_block(
    model_used: str,
    model_provider: str,
    data_class: str,
    doc_sources: list[dict],
    web_sources: list[dict],
    latency_ms: int,
) -> str:
    """
    Returns a markdown block appended to every response.
    Example output:
    ---
    📋 **Source Attribution**
    🤖 **Model**: Local LLM — llama3.2:3b (on-premise, Category A)
    📄 **Documents cited**: SOP-001-v2.pdf (QA workspace, p.3), ...
    🌐 **Web sources**: https://fda.gov/... (FDA guidance)
    ⚡ **Latency**: 3.2s
    """
    lines = ["\n\n---", "📋 **Source Attribution**\n"]

    # Model info
    if model_provider == "ollama":
        lines.append(f"🤖 **Model**: Local LLM — `{model_used}` *(on-premise, data never left your network)*")
    else:
        provider_map = {
            "openai":    "OpenAI (GPT-4o)",
            "anthropic": "Anthropic (Claude Sonnet)",
            "google":    "Google (Gemini Flash)",
        }
        label = provider_map.get(model_provider, model_provider)
        lines.append(f"☁️  **Model**: Cloud LLM — {label} *(Category C query — sanitized before sending)*")

    # Data classification
    class_labels = {
        "A": "🔴 Category A — Confidential (local model enforced)",
        "B": "🟡 Category B — Internal (abstracted before cloud)",
        "C": "🟢 Category C — General (cloud allowed)",
    }
    lines.append(f"🔒 **Data class**: {class_labels.get(data_class, data_class)}")

    # Document sources
    if doc_sources:
        lines.append(f"\n📄 **Local documents cited** ({len(doc_sources)} source{'s' if len(doc_sources)>1 else ''}):")
        for src in doc_sources:
            title   = src.get("title", src.get("name", "Unknown document"))
            page    = src.get("page", "")
            ws      = src.get("workspace", "")
            score   = src.get("score", "")
            detail  = " · ".join(filter(None, [
                f"Workspace: **{ws}**" if ws else "",
                f"p.{page}"             if page else "",
                f"relevance: {float(score):.0%}" if score else "",
            ]))
            lines.append(f"  - 📑 `{title}`{' — ' + detail if detail else ''}")
    else:
        lines.append("\n📄 **Local documents**: *(none cited for this query)*")

    # Web sources
    if web_sources:
        lines.append(f"\n🌐 **Web sources** ({len(web_sources)}):")
        for ws in web_sources:
            url   = ws.get("url", "")
            title = ws.get("title", url)
            lines.append(f"  - 🔗 [{title}]({url})")
    else:
        lines.append("🌐 **Web sources**: *(none — answer from local knowledge/documents)*")

    lines.append(f"\n⚡ **Response time**: {latency_ms / 1000:.1f}s")
    lines.append(f"🕐 **Timestamp**: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("---")

    return "\n".join(lines)


def detect_model_info(response_body: dict) -> tuple[str, str, str]:
    """Extract model name, provider, and data class from response metadata."""
    model     = response_body.get("model", "unknown")
    workspace = response_body.get("workspace", {})

    # Determine provider from model string
    if "llama" in model or "phi" in model or "nomic" in model or "mistral" in model:
        provider   = "ollama"
        data_class = "A"
    elif "gpt" in model:
        provider   = "openai"
        data_class = "C"
    elif "claude" in model:
        provider   = "anthropic"
        data_class = "C"
    elif "gemini" in model:
        provider   = "google"
        data_class = "C"
    else:
        provider   = "unknown"
        data_class = "B"

    return model, provider, data_class


def extract_sources(response_body: dict) -> tuple[list, list]:
    """Parse AnythingLLM response for document and web citations."""
    doc_sources = []
    web_sources = []

    # AnythingLLM returns sources in the 'sources' key
    sources = response_body.get("sources", [])
    for src in sources:
        src_type = src.get("type", "document")
        if src_type == "web" or src.get("url"):
            web_sources.append({
                "url":   src.get("url", ""),
                "title": src.get("title", src.get("url", "Web source")),
            })
        else:
            doc_sources.append({
                "title":     src.get("title", src.get("name", "Unknown")),
                "page":      src.get("page", ""),
                "workspace": src.get("workspaceName", ""),
                "score":     src.get("score", ""),
            })

    # Also check 'textResponse' for inline citation markers [doc:...]
    text = response_body.get("textResponse", "")
    cited = re.findall(r'\[doc:(.*?)\]', text)
    for c in cited:
        if not any(d["title"] == c for d in doc_sources):
            doc_sources.append({"title": c, "page": "", "workspace": "", "score": ""})

    return doc_sources, web_sources


# ─────────────────────────────────────────────────────────────
# Routes — proxy everything to AnythingLLM, intercept chat
# ─────────────────────────────────────────────────────────────

@app.api_route("/api/v1/workspace/{workspace_slug}/chat",
               methods=["POST"], name="workspace_chat")
async def workspace_chat(workspace_slug: str, request: Request):
    """
    Intercepts workspace chat calls.
    Appends source attribution block to every response.
    """
    body  = await request.json()
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}

    t0 = time.monotonic()

    async with httpx.AsyncClient(timeout=180) as client:
        resp = await client.post(
            f"{ANYTHINGLLM_URL}/api/v1/workspace/{workspace_slug}/chat",
            json=body,
            headers=headers,
        )

    latency_ms = int((time.monotonic() - t0) * 1000)

    if resp.status_code != 200:
        return Response(content=resp.content,
                        status_code=resp.status_code,
                        media_type=resp.headers.get("content-type"))

    data = resp.json()

    # ── Build attribution ──────────────────────────────────
    model, provider, data_class = detect_model_info(data)
    doc_sources, web_sources    = extract_sources(data)

    source_block = build_source_block(
        model_used    = model,
        model_provider= provider,
        data_class    = data_class,
        doc_sources   = doc_sources,
        web_sources   = web_sources,
        latency_ms    = latency_ms,
    )

    # Append to the text response
    original_text = data.get("textResponse", "")
    data["textResponse"] = original_text + source_block

    # Also store structured attribution in metadata
    data["_pharmacx_attribution"] = {
        "model":        model,
        "provider":     provider,
        "data_class":   data_class,
        "doc_sources":  doc_sources,
        "web_sources":  web_sources,
        "latency_ms":   latency_ms,
        "timestamp":    datetime.now(timezone.utc).isoformat(),
    }

    log.info(f"[{workspace_slug}] model={model} provider={provider} "
             f"docs={len(doc_sources)} web={len(web_sources)} {latency_ms}ms")

    return JSONResponse(content=data)


@app.api_route("/api/v1/workspace/{workspace_slug}/stream-chat",
               methods=["POST"], name="workspace_stream_chat")
async def workspace_stream_chat(workspace_slug: str, request: Request):
    """Streaming chat — injects source block after stream ends."""
    body    = await request.json()
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}

    t0 = time.monotonic()
    collected_text = []
    last_chunk_data: dict = {}

    async def generate() -> AsyncGenerator[bytes, None]:
        async with httpx.AsyncClient(timeout=180) as client:
            async with client.stream(
                "POST",
                f"{ANYTHINGLLM_URL}/api/v1/workspace/{workspace_slug}/stream-chat",
                json=body,
                headers=headers,
            ) as resp:
                async for chunk in resp.aiter_bytes():
                    # Collect text from SSE chunks for post-processing
                    try:
                        lines = chunk.decode("utf-8").split("\n")
                        for line in lines:
                            if line.startswith("data:"):
                                payload = line[5:].strip()
                                if payload and payload != "[DONE]":
                                    cd = json.loads(payload)
                                    if "textResponse" in cd:
                                        collected_text.append(
                                            cd.get("textResponse", ""))
                                        last_chunk_data.update(cd)
                    except Exception:
                        pass
                    yield chunk

        # After stream ends, emit source block as final SSE event
        latency_ms = int((time.monotonic() - t0) * 1000)
        model, provider, data_class = detect_model_info(last_chunk_data)
        doc_sources, web_sources    = extract_sources(last_chunk_data)

        source_block = build_source_block(
            model_used     = model,
            model_provider = provider,
            data_class     = data_class,
            doc_sources    = doc_sources,
            web_sources    = web_sources,
            latency_ms     = latency_ms,
        )

        attribution_event = {
            "type":          "sourceAttribution",
            "textResponse":  source_block,
            "attribution": {
                "model":       model,
                "provider":    provider,
                "data_class":  data_class,
                "doc_sources": doc_sources,
                "web_sources": web_sources,
                "latency_ms":  latency_ms,
            },
            "close": True,
        }
        yield f"data: {json.dumps(attribution_event)}\n\n".encode()
        yield b"data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


# ── Pass-through proxy for all other AnythingLLM routes ──────
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy(path: str, request: Request):
    """Transparent proxy for all non-chat endpoints."""
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length")}
    body    = await request.body()

    async with httpx.AsyncClient(timeout=60) as client:
        resp = await client.request(
            method  = request.method,
            url     = f"{ANYTHINGLLM_URL}/{path}",
            headers = headers,
            content = body,
            params  = dict(request.query_params),
        )

    return Response(
        content     = resp.content,
        status_code = resp.status_code,
        headers     = dict(resp.headers),
    )


@app.get("/health")
async def health():
    return {"status": "ok", "service": "pharmacx-source-tracker"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=5050, log_level="info")
