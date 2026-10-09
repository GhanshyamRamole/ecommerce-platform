
from pydantic import BaseModel, ConfigDict


class HealthResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    status: str
    version: str
    database: str | None = None
    timestamp: int


class DetailedHealthResponse(HealthResponse):
    checks: dict[str, bool]
