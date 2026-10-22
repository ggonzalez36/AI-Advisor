# syntax=docker/dockerfile:1

# --- Build stage: resolve dependencies from the lock file ---
FROM python:3.12-slim AS build
RUN pip install --no-cache-dir uv==0.11.3
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev

# --- Runtime stage: slim image, non-root, no build tools ---
FROM python:3.12-slim
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build --chown=10001:10001 /app /app
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LLM_PROVIDER=fake
USER 10001
EXPOSE 8000
# 0.0.0.0 is required inside the container; local development keeps --host 127.0.0.1.
CMD ["uvicorn", "src.api:app", "--host", "0.0.0.0", "--port", "8000"]
