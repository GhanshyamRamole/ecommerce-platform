import time

from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.db.session import get_db_session
from app.schemas.health import DetailedHealthResponse, HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
async def health_check(session: AsyncSession = Depends(get_db_session)) -> HealthResponse:
    settings = get_settings()
    db_status = "disconnected"
    try:
        await session.execute(text("SELECT 1"))
        db_status = "connected"
    except Exception:
        db_status = "error"

    return HealthResponse(
        status="healthy" if db_status == "connected" else "degraded",
        version=settings.APP_VERSION,
        database=db_status,
        timestamp=int(time.time()),
    )


@router.get("/health/detailed", response_model=DetailedHealthResponse)
async def detailed_health_check(session: AsyncSession = Depends(get_db_session)) -> DetailedHealthResponse:
    settings = get_settings()
    checks: dict[str, bool] = {}
    db_status = "disconnected"

    try:
        await session.execute(text("SELECT 1"))
        db_status = "connected"
        checks["database"] = True
    except Exception:
        db_status = "error"
        checks["database"] = False

    checks["api"] = True

    return DetailedHealthResponse(
        status="healthy" if all(checks.values()) else "degraded",
        version=settings.APP_VERSION,
        database=db_status,
        timestamp=int(time.time()),
        checks=checks,
    )
