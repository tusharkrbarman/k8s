import logging
import os
import time
from typing import Any
from urllib.parse import urlparse, urlunparse

import httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field


logger = logging.getLogger(__name__)

OVMS_URL = os.getenv(
    "OVMS_URL",
    "http://ovms-blue-service.llm-inference.svc.cluster.local:8000/v3/chat/completions",
)
MODEL_NAME = os.getenv(
    "MODEL_NAME",
    "OpenVINO/Phi-3-mini-FastDraft-50M-int8-ov",
)
API_KEY = os.getenv("API_KEY")
API_KEY_FILE = os.getenv("API_KEY_FILE")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("REQUEST_TIMEOUT_SECONDS", "60"))
READINESS_TIMEOUT_SECONDS = float(os.getenv("READINESS_TIMEOUT_SECONDS", "5"))

app = FastAPI(title="Kubernetes OpenVINO LLM Gateway")


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=2000)
    max_tokens: int = Field(default=32, ge=1, le=256)


class ChatResponse(BaseModel):
    answer: str
    model: str
    latency_seconds: float
    usage: dict[str, Any] | None = None


class ReadinessResponse(BaseModel):
    status: str
    api_key_configured: bool
    ovms_ready: bool
    ovms_config_url: str


def get_configured_api_key() -> str | None:
    if API_KEY:
        return API_KEY

    if API_KEY_FILE:
        try:
            with open(API_KEY_FILE, encoding="utf-8") as secret_file:
                return secret_file.read().strip()
        except OSError as exc:
            logger.error("failed_to_read_api_key_file path=%s error=%s", API_KEY_FILE, exc)
            return None

    return None


def get_ovms_config_url() -> str:
    parsed = urlparse(OVMS_URL)
    return urlunparse((parsed.scheme, parsed.netloc, "/v1/config", "", "", ""))


async def is_ovms_ready(config_url: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=READINESS_TIMEOUT_SECONDS) as client:
            response = await client.get(config_url)
            response.raise_for_status()
    except httpx.HTTPError as exc:
        logger.warning("ovms_readiness_check_failed url=%s error=%s", config_url, exc)
        return False

    return True


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/ready", response_model=ReadinessResponse)
async def ready() -> ReadinessResponse:
    api_key_configured = get_configured_api_key() is not None
    ovms_config_url = get_ovms_config_url()

    if not api_key_configured:
        payload = ReadinessResponse(
            status="not_ready",
            api_key_configured=False,
            ovms_ready=False,
            ovms_config_url=ovms_config_url,
        )
        raise HTTPException(status_code=503, detail=payload.model_dump())

    ovms_ready = await is_ovms_ready(ovms_config_url)
    if not ovms_ready:
        payload = ReadinessResponse(
            status="not_ready",
            api_key_configured=True,
            ovms_ready=False,
            ovms_config_url=ovms_config_url,
        )
        raise HTTPException(status_code=503, detail=payload.model_dump())

    return ReadinessResponse(
        status="ready",
        api_key_configured=True,
        ovms_ready=True,
        ovms_config_url=ovms_config_url,
    )


@app.post("/chat", response_model=ChatResponse)
async def chat(
    request: ChatRequest,
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> ChatResponse:
    configured_api_key = get_configured_api_key()
    if not configured_api_key:
        raise HTTPException(status_code=500, detail="Gateway API key is not configured")

    if x_api_key != configured_api_key:
        raise HTTPException(status_code=401, detail="Invalid API key")

    payload = {
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": request.message}],
        "max_tokens": request.max_tokens,
    }

    started = time.perf_counter()
    try:
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS) as client:
            response = await client.post(OVMS_URL, json=payload)
            response.raise_for_status()
    except httpx.HTTPStatusError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"OVMS returned HTTP {exc.response.status_code}: {exc.response.text}",
        ) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"OVMS request failed: {exc}") from exc

    elapsed = round(time.perf_counter() - started, 3)
    body = response.json()
    logger.info(
        "chat_completion model=%s latency_seconds=%s prompt_tokens=%s completion_tokens=%s total_tokens=%s",
        body.get("model", MODEL_NAME),
        elapsed,
        body.get("usage", {}).get("prompt_tokens"),
        body.get("usage", {}).get("completion_tokens"),
        body.get("usage", {}).get("total_tokens"),
    )
    answer = (
        body.get("choices", [{}])[0]
        .get("message", {})
        .get("content", "")
    )

    return ChatResponse(
        answer=answer,
        model=body.get("model", MODEL_NAME),
        latency_seconds=elapsed,
        usage=body.get("usage"),
    )
