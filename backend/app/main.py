import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError

from app.core.config import settings
from app.db.session import get_session_factory, initialize_database
from app.api.folders import router as folders_router
from app.api.transcripts import router as transcripts_router
from app.api.summaries import router as summaries_router
from app.api.audio_sessions import router as audio_router
from app.api.templates import router as templates_router
from app.api.template_previews import router as previews_router

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app):
    if settings.database_url:
        initialize_database(get_session_factory())
    yield


app = FastAPI(title="YourMettings", version="0.1.0", lifespan=lifespan)
app.include_router(transcripts_router, prefix="/api/v1")
app.include_router(folders_router, prefix="/api/v1")
app.include_router(summaries_router, prefix="/api/v1")
app.include_router(audio_router, prefix="/api/v1")
app.include_router(templates_router, prefix="/api/v1")
app.include_router(previews_router, prefix="/api/v1")


@app.exception_handler(HTTPException)
async def http_error(request: Request, exc: HTTPException):
    detail = exc.detail if isinstance(exc.detail, dict) else {
        "code": "http_error", "message": str(exc.detail), "details": {}}
    return JSONResponse(status_code=exc.status_code, content={"error": detail})


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    # Do not echo transcript text or arbitrary client input in validation errors.
    details = [{"field": list(e["loc"]), "type": e["type"]} for e in exc.errors()]
    return JSONResponse(status_code=422, content={"error": {
        "code": "validation_error", "message": "Некорректные параметры запроса.", "details": {"fields": details}}})


@app.exception_handler(OperationalError)
async def database_error(request: Request, exc: OperationalError):
    logger.error("Database unavailable on %s", request.url.path)
    return JSONResponse(status_code=503, content={"error": {
        "code": "database_unavailable", "message": "База данных временно недоступна.", "details": {}}})


@app.exception_handler(Exception)
async def internal_error(request: Request, exc: Exception):
    logger.error("Unexpected %s on %s", type(exc).__name__, request.url.path)
    return JSONResponse(status_code=500, content={"error": {
        "code": "internal_error", "message": "Внутренняя ошибка сервера.", "details": {}}})


@app.get("/health", tags=["health"])
def health() -> dict[str, str]:
    return {"status": "ok"}
